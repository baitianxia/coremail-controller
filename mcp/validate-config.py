#!/usr/bin/env python3
"""Validate a staged mail configuration without opening a connection."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


# Isolated mode intentionally omits the script directory from sys.path. Add
# only this packaged MCP directory so validation imports the exact staged
# backend instead of ambient user/site modules.
MCP_ROOT = Path(__file__).resolve().parent
if str(MCP_ROOT) not in sys.path:
    sys.path.insert(0, str(MCP_ROOT))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("config", type=Path)
    arguments = parser.parse_args()
    config = arguments.config.resolve()
    if not config.is_file():
        parser.error(f"configuration is not a regular file: {config}")

    try:
        from coremail_backend import load_settings

        load_settings(config)
    except Exception as exc:  # boundary: convert validation failures to a stable exit
        print(f"Invalid mail configuration: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
