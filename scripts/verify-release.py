#!/usr/bin/env python3
"""Verify the internal Coremail release manifest and Windows gate metadata."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import sys
from pathlib import Path
from typing import Any


COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
OPTIONAL_INSTALLED_FILE = "mcp/python-runtime.json"


class VerificationError(RuntimeError):
    pass


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def is_link_or_reparse(path: Path) -> bool:
    if path.is_symlink():
        return True
    attributes = getattr(path.lstat(), "st_file_attributes", 0)
    return bool(attributes & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0))


def require_object(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise VerificationError(f"{label} must be an object")
    return value


def verify(root: Path, *, require_windows_gate: bool, allow_python_runtime: bool) -> None:
    root = root.resolve(strict=True)
    if not root.is_dir():
        raise VerificationError(f"release root is not a directory: {root}")
    manifest_path = root / "FILE-MANIFEST.json"
    metadata_path = root / "BUILD-METADATA.json"
    try:
        manifest = require_object(json.loads(manifest_path.read_text("utf-8")), "manifest")
        metadata = require_object(json.loads(metadata_path.read_text("utf-8")), "metadata")
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise VerificationError(f"cannot read release metadata: {exc}") from exc
    if manifest.get("schema_version") != 1:
        raise VerificationError("unsupported file manifest schema")
    entries = manifest.get("files")
    if not isinstance(entries, list) or not entries:
        raise VerificationError("file manifest must contain a non-empty files array")

    expected: dict[str, tuple[int, str]] = {}
    for entry_value in entries:
        entry = require_object(entry_value, "manifest entry")
        path_value = entry.get("path")
        size = entry.get("size")
        digest = entry.get("sha256")
        if not isinstance(path_value, str) or not path_value or "\\" in path_value:
            raise VerificationError("manifest path must be a non-empty POSIX relative path")
        relative = Path(path_value)
        if relative.is_absolute() or ".." in relative.parts or path_value in expected:
            raise VerificationError(f"unsafe or duplicate manifest path: {path_value}")
        if isinstance(size, bool) or not isinstance(size, int) or size < 0:
            raise VerificationError(f"invalid file size for {path_value}")
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise VerificationError(f"invalid SHA-256 for {path_value}")
        expected[path_value] = (size, digest)

    actual: set[str] = set()
    for directory, dirnames, filenames in os.walk(root, followlinks=False):
        directory_path = Path(directory)
        for name in sorted(dirnames + filenames):
            path = directory_path / name
            relative = path.relative_to(root).as_posix()
            if is_link_or_reparse(path):
                raise VerificationError(f"link or reparse point is forbidden: {relative}")
        for name in filenames:
            actual.add((directory_path / name).relative_to(root).as_posix())

    allowed_unhashed = {"FILE-MANIFEST.json"}
    if allow_python_runtime:
        allowed_unhashed.add(OPTIONAL_INSTALLED_FILE)
    if actual != set(expected) | allowed_unhashed:
        missing = sorted((set(expected) | {"FILE-MANIFEST.json"}) - actual)
        extra = sorted(actual - (set(expected) | allowed_unhashed))
        raise VerificationError(f"release file set mismatch; missing={missing}; extra={extra}")
    for relative, (expected_size, expected_digest) in expected.items():
        path = root / relative
        if not path.is_file() or path.stat().st_size != expected_size:
            raise VerificationError(f"size mismatch: {relative}")
        if sha256(path) != expected_digest:
            raise VerificationError(f"SHA-256 mismatch: {relative}")

    if metadata.get("schema_version") != 1 or metadata.get("version") != "0.7.0":
        raise VerificationError("unsupported build metadata identity")
    if require_windows_gate:
        required = {
            "build_host": {"system": "windows", "machine": "x64"},
            "target": {"system": "windows", "machine": "x64"},
            "release_channel": "windows-native-gated",
            "cross_built": False,
            "target_mcp_smoke_tested": True,
        }
        for key, value in required.items():
            if metadata.get(key) != value:
                raise VerificationError(f"Windows-gated metadata mismatch: {key}")
        commit = metadata.get("source_commit")
        if not isinstance(commit, str) or not COMMIT_RE.fullmatch(commit):
            raise VerificationError("Windows-gated metadata has no exact source commit")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("--require-windows-gate", action="store_true")
    parser.add_argument("--allow-python-runtime", action="store_true")
    arguments = parser.parse_args()
    try:
        verify(
            arguments.root,
            require_windows_gate=arguments.require_windows_gate,
            allow_python_runtime=arguments.allow_python_runtime,
        )
    except (OSError, VerificationError) as exc:
        print(f"INVALID COREMAIL RELEASE: {exc}", file=sys.stderr)
        return 2
    print("COREMAIL RELEASE: VERIFIED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
