#!/usr/bin/env python3
"""Describe the exact Python interpreter selected during Windows installation."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import struct
import sys
import tempfile
from pathlib import Path


SCHEMA_VERSION = 1


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def describe() -> dict[str, object]:
    executable = Path(sys.executable).resolve(strict=True)
    if not executable.is_file():
        raise RuntimeError(f"Python executable is not a regular file: {executable}")
    return {
        "schema_version": SCHEMA_VERSION,
        "kind": "python",
        "bundled": True,
        "executable": str(executable),
        "version": f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}",
        "version_info": [
            sys.version_info.major,
            sys.version_info.minor,
            sys.version_info.micro,
        ],
        "pointer_bits": struct.calcsize("P") * 8,
        "executable_sha256": file_sha256(executable),
    }


def write_atomically(path: Path, payload: dict[str, object]) -> None:
    path = path.resolve()
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(payload, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_name, path)
    except BaseException:
        try:
            os.close(descriptor)
        except OSError:
            pass
        Path(temporary_name).unlink(missing_ok=True)
        raise


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    arguments = parser.parse_args()
    if sys.version_info[:2] < (3, 10):
        print("Python 3.10 or newer is required.", file=sys.stderr)
        return 10
    try:
        write_atomically(arguments.output, describe())
    except (OSError, RuntimeError, ValueError) as exc:
        print(f"Unable to describe the selected Python runtime: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
