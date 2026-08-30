#!/usr/bin/env python3
"""Build a Windows release candidate ZIP and adjacent SHA-256 file.

The archive is releasable only after the packaged Windows PowerShell 5.1
lifecycle gate succeeds in CI.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import tempfile
import zipfile
from pathlib import Path


VERSION = "0.6.0"
BUNDLE_NAME = f"coremail-controller-{VERSION}"
ARCHIVE_NAME = f"{BUNDLE_NAME}-windows.zip"

# Release contents are allowlisted so caches, credentials, live configuration,
# VCS data, and arbitrary untracked files cannot silently enter the package.
EXACT_FILES = (
    ".claude-plugin/plugin.json",
    ".gitignore",
    ".mcp.json",
    "CHANGELOG.md",
    "CONFIGURE-ACCOUNT.cmd",
    "INSTALL.cmd",
    "LICENSE",
    "README.md",
    "START-HERE.md",
    "UNINSTALL.cmd",
    "docs/architecture.md",
    "docs/browser-orchestration.md",
    "mcp/check-python.py",
    "mcp/coremail_backend.py",
    "mcp/local_discovery.py",
    "mcp/run-server.ps1",
    "mcp/server.py",
    "mcp/windows_mapi.py",
    "scripts/build-release.py",
    "scripts/configure-account.ps1",
    "scripts/install.ps1",
    "scripts/setup-account.ps1",
    "scripts/uninstall.ps1",
    "skills/coremail/SKILL.md",
    "skills/web-to-coremail/SKILL.md",
    "tests/smoke-mcp.ps1",
    "tests/run-windows-release-gate.ps1",
    "tests/windows-lifecycle.ps1",
    "tests/test_backend.py",
    "tests/test_protocol.py",
    "tests/test_release.py",
    "tests/test_windows_mapi.py",
)


class ReleaseError(RuntimeError):
    """Raised when a release cannot be built safely."""


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validated_files(project_root: Path) -> list[Path]:
    files: list[Path] = []
    for value in EXACT_FILES:
        relative = Path(value)
        source = project_root / relative
        if source.is_symlink() or not source.is_file():
            raise ReleaseError(f"required release file is missing or not regular: {relative}")
        files.append(relative)

    manifest = json.loads(
        (project_root / ".claude-plugin" / "plugin.json").read_text(encoding="utf-8")
    )
    if manifest.get("name") != "coremail-controller":
        raise ReleaseError("unexpected plugin identity")
    if manifest.get("version") != VERSION:
        raise ReleaseError(
            f"release version {VERSION} does not match plugin version {manifest.get('version')}"
        )
    return files


def build_release(
    project_root: Path, output_directory: Path, *, force: bool = False
) -> tuple[Path, Path]:
    project_root = project_root.resolve()
    output_directory = output_directory.resolve()
    files = validated_files(project_root)
    output_directory.mkdir(parents=True, exist_ok=True)
    archive = output_directory / ARCHIVE_NAME
    sidecar = Path(f"{archive}.sha256")
    if not force and (archive.exists() or sidecar.exists()):
        raise ReleaseError(f"refusing to overwrite {archive}; pass --force")

    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{ARCHIVE_NAME}.", suffix=".tmp", dir=output_directory
    )
    os.close(descriptor)
    temporary_archive = Path(temporary_name)
    temporary_sidecar = Path(f"{temporary_archive}.sha256")
    try:
        with zipfile.ZipFile(
            temporary_archive,
            mode="w",
            compression=zipfile.ZIP_DEFLATED,
            compresslevel=9,
        ) as bundle:
            for relative in files:
                bundle.write(
                    project_root / relative,
                    arcname=(Path(BUNDLE_NAME) / relative).as_posix(),
                )
        digest = sha256(temporary_archive)
        temporary_sidecar.write_bytes(
            f"{digest}  {ARCHIVE_NAME}\n".encode("ascii")
        )
        os.replace(temporary_archive, archive)
        os.replace(temporary_sidecar, sidecar)
    finally:
        temporary_archive.unlink(missing_ok=True)
        temporary_sidecar.unlink(missing_ok=True)
    return archive, sidecar


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, default=Path("dist"))
    parser.add_argument("--force", action="store_true")
    arguments = parser.parse_args()
    project_root = Path(__file__).resolve().parents[1]
    try:
        archive, sidecar = build_release(
            project_root, arguments.output_dir, force=arguments.force
        )
    except (OSError, ValueError, json.JSONDecodeError, ReleaseError) as exc:
        print(f"ERROR: {exc}")
        return 2
    print(f"Built candidate (not release-gated locally): {archive}")
    print(f"Checksum: {sidecar}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
