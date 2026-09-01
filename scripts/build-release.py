#!/usr/bin/env python3
"""Build an allowlisted Coremail Controller Windows archive."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import tempfile
import zipfile
from pathlib import Path


VERSION = "0.7.0"
BUNDLE_NAME = f"coremail-controller-{VERSION}"
LOCAL_ARCHIVE_NAME = f"{BUNDLE_NAME}-windows-UNVERIFIED.zip"
GATED_ARCHIVE_NAME = f"{BUNDLE_NAME}-windows.zip"
ARCHIVE_NAME = LOCAL_ARCHIVE_NAME
GENERATED_FILES = ("BUILD-METADATA.json", "FILE-MANIFEST.json")

# Every source file shipped to users is reviewed here. Generated metadata and
# the internal hash manifest are added separately by build_release.
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
    "mcp/describe-python.py",
    "mcp/local_discovery.py",
    "mcp/run-server.ps1",
    "mcp/server.py",
    "mcp/validate-config.py",
    "mcp/windows_mapi.py",
    "scripts/build-release.py",
    "scripts/configure-account.ps1",
    "scripts/install.ps1",
    "scripts/setup-account.ps1",
    "scripts/uninstall.ps1",
    "scripts/verify-release.py",
    "scripts/verify-claude-plugin-list.py",
    "scripts/windows-credential.ps1",
    "scripts/windows-lifecycle-common.ps1",
    "scripts/windows-tool-discovery.ps1",
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

COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")


class ReleaseError(RuntimeError):
    """Raised when a release cannot be built safely."""


def normalized_system() -> str:
    value = platform.system().lower()
    return "windows" if value.startswith("win") else value


def normalized_machine() -> str:
    value = platform.machine().lower()
    if value in {"amd64", "x86_64"}:
        return "x64"
    if value in {"aarch64", "arm64"}:
        return "arm64"
    return value


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def bytes_sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def json_bytes(payload: object) -> bytes:
    return (json.dumps(payload, indent=2, sort_keys=True) + "\n").encode("utf-8")


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


def build_metadata(*, windows_gate: bool, source_commit: str | None) -> dict[str, object]:
    system = normalized_system()
    machine = normalized_machine()
    if windows_gate:
        if system != "windows" or machine != "x64":
            raise ReleaseError("the gated artifact must be built on Windows x64")
        if os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get(
            "RUNNER_ENVIRONMENT"
        ) != "github-hosted":
            raise ReleaseError("the gated artifact requires a GitHub-hosted runner")
        if source_commit is None or not COMMIT_RE.fullmatch(source_commit.lower()):
            raise ReleaseError("the gated artifact requires an exact 40-character source commit")
    commit = source_commit.lower() if source_commit else None
    return {
        "schema_version": 1,
        "version": VERSION,
        "source_commit": commit,
        "build_host": {"system": system, "machine": machine},
        "target": {"system": "windows", "machine": "x64"},
        "release_channel": "windows-native-gated" if windows_gate else "local-unverified",
        "cross_built": system != "windows" or machine != "x64",
        "target_mcp_smoke_tested": windows_gate,
    }


def build_release(
    project_root: Path,
    output_directory: Path,
    *,
    force: bool = False,
    windows_gate: bool = False,
    source_commit: str | None = None,
) -> tuple[Path, Path]:
    project_root = project_root.resolve()
    output_directory = output_directory.resolve()
    files = validated_files(project_root)
    metadata_bytes = json_bytes(
        build_metadata(windows_gate=windows_gate, source_commit=source_commit)
    )

    manifest_entries: list[dict[str, object]] = []
    for relative in files:
        payload = (project_root / relative).read_bytes()
        manifest_entries.append(
            {"path": relative.as_posix(), "size": len(payload), "sha256": bytes_sha256(payload)}
        )
    manifest_entries.append(
        {
            "path": "BUILD-METADATA.json",
            "size": len(metadata_bytes),
            "sha256": bytes_sha256(metadata_bytes),
        }
    )
    manifest_entries.sort(key=lambda item: str(item["path"]))
    file_manifest_bytes = json_bytes(
        {"schema_version": 1, "files": manifest_entries}
    )

    output_directory.mkdir(parents=True, exist_ok=True)
    archive_name = GATED_ARCHIVE_NAME if windows_gate else LOCAL_ARCHIVE_NAME
    archive = output_directory / archive_name
    sidecar = Path(f"{archive}.sha256")
    if not force and (archive.exists() or sidecar.exists()):
        raise ReleaseError(f"refusing to overwrite {archive}; pass --force")

    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{archive_name}.", suffix=".tmp", dir=output_directory
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
            bundle.writestr(
                (Path(BUNDLE_NAME) / "BUILD-METADATA.json").as_posix(),
                metadata_bytes,
            )
            bundle.writestr(
                (Path(BUNDLE_NAME) / "FILE-MANIFEST.json").as_posix(),
                file_manifest_bytes,
            )
        digest = sha256(temporary_archive)
        temporary_sidecar.write_bytes(f"{digest}  {archive_name}\n".encode("ascii"))
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
    parser.add_argument("--windows-gate", action="store_true")
    parser.add_argument("--source-commit")
    arguments = parser.parse_args()
    project_root = Path(__file__).resolve().parents[1]
    try:
        archive, sidecar = build_release(
            project_root,
            arguments.output_dir,
            force=arguments.force,
            windows_gate=arguments.windows_gate,
            source_commit=arguments.source_commit,
        )
    except (OSError, ValueError, json.JSONDecodeError, ReleaseError) as exc:
        print(f"ERROR: {exc}")
        return 2
    qualifier = "Windows-gated input" if arguments.windows_gate else "UNVERIFIED local candidate"
    print(f"Built {qualifier}: {archive}")
    print(f"Checksum: {sidecar}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
