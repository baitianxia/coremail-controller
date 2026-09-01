#!/usr/bin/env python3
"""Verify one exact skills-directory plugin in Claude Code JSON inventory."""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any


class InventoryError(RuntimeError):
    pass


def normalize_path(value: str) -> str:
    return os.path.normcase(os.path.abspath(value))


def installed_entries(payload: Any) -> list[dict[str, Any]]:
    if isinstance(payload, list):
        values = payload
    elif isinstance(payload, dict) and isinstance(payload.get("installed"), list):
        values = payload["installed"]
    else:
        raise InventoryError("Claude plugin inventory must be an array or contain installed[]")
    return [value for value in values if isinstance(value, dict)]


def verify(
    payload: Any,
    *,
    plugin_id: str,
    version: str,
    expected_path: Path,
    state: str,
) -> None:
    matches = [entry for entry in installed_entries(payload) if entry.get("id") == plugin_id]
    if len(matches) != 1:
        raise InventoryError(
            f"expected exactly one {plugin_id!r} inventory record, found {len(matches)}"
        )
    entry = matches[0]
    if entry.get("version") != version:
        raise InventoryError(
            f"plugin inventory version is {entry.get('version')!r}, expected {version!r}"
        )
    install_path = entry.get("installPath")
    if not isinstance(install_path, str) or normalize_path(install_path) != normalize_path(
        str(expected_path)
    ):
        raise InventoryError("plugin inventory points at an unexpected installPath")
    enabled = entry.get("enabled")
    if not isinstance(enabled, bool):
        raise InventoryError("plugin inventory has no boolean enabled state")
    if state == "enabled" and not enabled:
        raise InventoryError("plugin remains disabled")
    if state == "disabled" and enabled:
        raise InventoryError("plugin remains enabled")
    errors = entry.get("errors", [])
    if errors not in (None, [], {}):
        raise InventoryError(f"plugin inventory reports load errors: {errors!r}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inventory", type=Path)
    parser.add_argument("--plugin-id", default="coremail-controller@skills-dir")
    parser.add_argument("--version", default="0.7.0")
    parser.add_argument("--expected-path", required=True, type=Path)
    parser.add_argument("--state", choices=("present", "enabled", "disabled"), required=True)
    arguments = parser.parse_args()
    try:
        payload = json.loads(arguments.inventory.read_text(encoding="utf-8-sig"))
        verify(
            payload,
            plugin_id=arguments.plugin_id,
            version=arguments.version,
            expected_path=arguments.expected_path,
            state=arguments.state,
        )
    except (OSError, UnicodeDecodeError, json.JSONDecodeError, InventoryError) as exc:
        print(f"INVALID CLAUDE PLUGIN STATE: {exc}", file=sys.stderr)
        return 2
    print("CLAUDE PLUGIN STATE: VERIFIED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
