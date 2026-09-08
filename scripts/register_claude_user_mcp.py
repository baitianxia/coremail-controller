#!/usr/bin/env python3
"""Transactionally register the mail assistant in Claude Code's user MCP scope.

The mail package deliberately uses Claude Code's stable ``mcp`` command
instead of the newer plugin inventory/enablement commands.  This keeps the
mail server usable with older Claude Code releases (including 2.1.84) while
still making the registration explicit, user-scoped, and reversible.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import textwrap
import uuid
from pathlib import Path
from typing import Callable, Mapping, Sequence


class RegistrationError(RuntimeError):
    """Raised when a Claude user-scope transaction cannot be completed."""


Reporter = Callable[[str], None]
SERVER_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$")


def _configure_standard_streams() -> None:
    """Keep diagnostics printable on legacy Windows console code pages."""
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if callable(reconfigure):
            reconfigure(errors="backslashreplace")


def _validated_server_name(value: str) -> str:
    if not isinstance(value, str) or not SERVER_NAME_RE.fullmatch(value):
        raise RegistrationError(
            "server name must contain only letters, digits, '-' or '_' and be at most 128 characters"
        )
    return value


def _regular_file(path: Path, label: str) -> Path:
    """Return a regular, non-link file path or raise a safe error."""
    try:
        metadata = path.lstat()
        if _is_reparse_metadata(metadata) or not stat.S_ISREG(metadata.st_mode):
            raise RegistrationError(f"{label} is not a regular file: {path}")
    except FileNotFoundError as exc:
        raise RegistrationError(f"{label} is not a regular file: {path}") from exc
    except OSError as exc:
        raise RegistrationError(f"cannot inspect {label}: {path}: {exc}") from exc
    return path


def _is_reparse_metadata(metadata: os.stat_result) -> bool:
    """Detect links/reparse points from an already acquired lstat result."""
    # FILE_ATTRIBUTE_REPARSE_POINT is 0x400.  Keep the literal here so the
    # registrar remains standard-library-only on every supported host.
    # The package itself is Windows-only.  On POSIX development hosts /var is
    # commonly a compatibility symlink to /private/var; rejecting that ancestor
    # would make the offline transaction self-test fail before it starts.
    # Windows reparse metadata remains fail-closed, including Windows symlinks
    # whose mode bit is not consistently exposed.
    return bool(getattr(metadata, "st_file_attributes", 0) & 0x400) or (
        os.name == "nt" and stat.S_ISLNK(metadata.st_mode)
    )


def _is_reparse_point(path: Path) -> bool:
    """Detect Windows reparse points without resolving the path.

    A path that cannot be inspected is unsafe for a configuration mutation, so
    inspection errors are surfaced instead of being treated as a normal file.
    """
    try:
        return _is_reparse_metadata(path.lstat())
    except FileNotFoundError:
        return False
    except (OSError, ValueError) as exc:
        raise RegistrationError(f"cannot inspect path for links or junctions: {path}") from exc


def _validate_path_chain(path: Path, label: str) -> None:
    """Reject links/reparse points in an existing path chain.

    The PowerShell lifecycle resolver performs the same check before invoking
    this helper.  Repeating it here protects direct CLI use and prevents a
    link swap between the resolver and the actual config mutation.
    """
    try:
        absolute = Path(os.path.abspath(path))
    except (OSError, ValueError) as exc:
        raise RegistrationError(f"{label} is not a valid path: {path}") from exc
    # Walk all the way to the filesystem root.  Stopping at the first existing
    # component is not sufficient: an existing directory can itself be below a
    # junction/symlink whose target happens to contain the requested path.
    # Every existing component must be inspected independently.
    current = absolute
    while True:
        try:
            metadata = current.lstat()
        except FileNotFoundError:
            metadata = None
        except OSError as exc:
            raise RegistrationError(f"cannot inspect {label}: {current}: {exc}") from exc
        if metadata is not None:
            if _is_reparse_metadata(metadata):
                raise RegistrationError(
                    f"{label} traverses an unsupported link or junction: {current}"
                )
        parent = current.parent
        if parent == current:
            break
        current = parent


def _validate_config_path(path: Path, label: str) -> None:
    _validate_path_chain(path, label)
    try:
        metadata = path.lstat()
        if _is_reparse_metadata(metadata):
            raise RegistrationError(f"{label} is an unsupported link or junction: {path}")
        if not stat.S_ISREG(metadata.st_mode):
            raise RegistrationError(f"{label} is not a regular file: {path}")
    except FileNotFoundError:
        return
    except OSError as exc:
        raise RegistrationError(f"cannot inspect {label}: {path}: {exc}") from exc


def _atomic_copy(source: Path, destination: Path, *, overwrite: bool) -> None:
    _regular_file(source, "backup source")
    _validate_config_path(destination, "rollback backup")
    if destination.exists() and not overwrite:
        raise RegistrationError(f"refusing to overwrite backup: {destination}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(
        f".{destination.name}.tmp-{os.getpid()}-{uuid.uuid4().hex[:8]}"
    )
    try:
        shutil.copy2(source, temporary)
        os.replace(temporary, destination)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def _native_command(
    executable: str, prefix: Sequence[str], arguments: Sequence[str]
) -> list[str]:
    return [executable, *prefix, *arguments]


def _run_claude(
    executable: str,
    prefix: Sequence[str],
    arguments: Sequence[str],
    *,
    environment: Mapping[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    command = _native_command(executable, prefix, arguments)
    try:
        return subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=90,
            env=dict(environment) if environment is not None else None,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise RegistrationError(f"cannot execute Claude Code CLI: {exc}") from exc


def _redacted_failure(
    command_name: str,
    result: subprocess.CompletedProcess[str],
    *,
    secrets: Sequence[str] = (),
) -> str:
    def redact(value: str) -> str:
        for secret in secrets:
            if secret:
                value = value.replace(secret, "<redacted>")
        return value

    details = [f"{command_name} exited with code {result.returncode}"]
    if result.stdout.strip():
        details.append("stdout: " + redact(result.stdout.strip())[-2000:])
    if result.stderr.strip():
        details.append("stderr: " + redact(result.stderr.strip())[-2000:])
    return "; ".join(details)


def _is_missing_result(result: subprocess.CompletedProcess[str]) -> bool:
    """Recognize the wording used by Claude 2.1.84 and current releases."""
    output = f"{result.stdout}\n{result.stderr}"
    normalized = re.sub(r"[\"'` ]+", " ", output).lower()
    patterns = (
        r"\bno\s+(?:user-scoped\s+)?mcp\s+server\s+found\s+with\s+name\b",
        r"\bno\s+mcp\s+server\s+(?:found|configured|named)\b",
        r"\bserver\s+is\s+missing\b",
    )
    return any(re.search(pattern, normalized) for pattern in patterns)


def _read_config(path: Path) -> dict[str, object]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise RegistrationError(f"cannot read Claude user configuration: {exc}") from exc
    if not isinstance(payload, dict):
        raise RegistrationError("Claude user configuration root is not an object")
    return payload


def _restore_user_config(
    user_config: Path,
    backup: Path,
    *,
    was_present: bool,
) -> None:
    if was_present:
        _regular_file(backup, "rollback backup")
        _atomic_copy(backup, user_config, overwrite=True)
    else:
        try:
            metadata = user_config.lstat()
        except FileNotFoundError:
            return
        except OSError as exc:
            raise RegistrationError(
                f"cannot inspect new Claude user configuration: {user_config}: {exc}"
            ) from exc
        if _is_reparse_metadata(metadata) or not stat.S_ISREG(metadata.st_mode):
            raise RegistrationError(
                f"refusing to remove non-file Claude user configuration: {user_config}"
            )
        user_config.unlink()


def _same_path(left: str, right: str) -> bool:
    """Compare Windows paths case-insensitively and normalize separators."""
    if os.name == "nt":
        def normalized(value: str) -> str:
            try:
                value = os.path.abspath(value)
            except (OSError, ValueError):
                pass
            return os.path.normcase(value).replace("/", "\\").rstrip("\\")

        return normalized(left) == normalized(right)
    return left == right


def _verify_entry(
    user_config: Path,
    *,
    server_name: str,
    powershell_executable: Path,
    server_script: Path,
) -> None:
    payload = _read_config(user_config)
    servers = payload.get("mcpServers")
    entry = servers.get(server_name) if isinstance(servers, dict) else None
    if not isinstance(entry, dict):
        raise RegistrationError(
            f"user-scoped MCP entry was not written: {server_name}"
        )
    unexpected = set(entry) - {"type", "command", "args", "env"}
    if unexpected:
        raise RegistrationError(
            "user-scoped MCP entry contains unexpected fields: "
            + ", ".join(sorted(unexpected))
        )
    if entry.get("type") not in {None, "stdio"}:
        raise RegistrationError("Mail user MCP transport is not stdio")
    command = entry.get("command")
    arguments = entry.get("args")
    expected_arguments = [
        "-NoLogo",
        "-NoProfile",
        "-NonInteractive",
        "-File",
        str(server_script),
    ]
    if not isinstance(command, str) or not _same_path(
        command, str(powershell_executable)
    ):
        raise RegistrationError(
            "user-scoped MCP entry does not match the verified PowerShell executable"
        )
    if not isinstance(arguments, list) or len(arguments) != len(expected_arguments):
        raise RegistrationError("user-scoped MCP arguments have an unexpected shape")
    for index, (actual, expected) in enumerate(zip(arguments, expected_arguments)):
        if not isinstance(actual, str):
            raise RegistrationError("user-scoped MCP arguments must all be strings")
        if index == len(expected_arguments) - 1:
            matches = _same_path(actual, expected)
        else:
            matches = actual == expected
        if not matches:
            raise RegistrationError(
                "user-scoped MCP entry does not match the verified server script path"
            )
    environment = entry.get("env")
    if environment not in (None, {}):
        raise RegistrationError(
            "Mail user MCP registration must not inject environment secrets"
        )


def _verify_absent(user_config: Path, server_name: str) -> None:
    _validate_config_path(user_config, "Claude user configuration")
    if not user_config.exists():
        return
    payload = _read_config(user_config)
    servers = payload.get("mcpServers")
    if isinstance(servers, dict) and server_name in servers:
        raise RegistrationError(
            f"user-scoped MCP entry is still present after removal: {server_name}"
        )


def _validate_inputs(
    *,
    claude_executable: str,
    claude_prefix: Sequence[str],
    server_name: str,
    powershell_executable: Path | None,
    server_script: Path | None,
    user_config: Path,
    backup: Path,
) -> None:
    _validated_server_name(server_name)
    if not claude_executable or "\x00" in claude_executable:
        raise RegistrationError("resolved Claude executable is invalid")
    if any(not isinstance(item, str) or "\x00" in item for item in claude_prefix):
        raise RegistrationError("resolved Claude prefix is invalid")
    if os.name == "nt" and not claude_executable.lower().endswith(".exe"):
        # The installer resolves npm .cmd launchers to node.exe before calling
        # this script.  Refusing a .cmd here prevents accidental cmd.exe
        # re-parsing of paths and arguments.
        raise RegistrationError("the resolved Claude launcher must be a Windows .exe")
    if powershell_executable is not None:
        _regular_file(powershell_executable, "PowerShell executable")
        if os.name == "nt" and powershell_executable.suffix.lower() != ".exe":
            raise RegistrationError("PowerShell executable must end in .exe")
    if server_script is not None:
        _regular_file(server_script, "mail MCP launcher")
        if server_script.suffix.lower() != ".ps1":
            raise RegistrationError("mail MCP launcher must be a .ps1 file")
    _validate_config_path(user_config, "Claude user configuration")
    _validate_config_path(backup, "rollback backup")
    if backup.exists():
        raise RegistrationError(f"refusing to overwrite rollback backup: {backup}")


def register_user_mcp(
    *,
    claude_executable: str,
    claude_prefix: Sequence[str],
    server_name: str,
    powershell_executable: Path,
    server_script: Path,
    user_config: Path,
    backup: Path,
    reporter: Reporter = print,
    environment: Mapping[str, str] | None = None,
) -> None:
    _validate_inputs(
        claude_executable=claude_executable,
        claude_prefix=claude_prefix,
        server_name=server_name,
        powershell_executable=powershell_executable,
        server_script=server_script,
        user_config=user_config,
        backup=backup,
    )
    was_present = user_config.is_file()
    if was_present:
        _atomic_copy(user_config, backup, overwrite=False)
    try:
        remove_result = _run_claude(
            claude_executable,
            claude_prefix,
            ("mcp", "remove", server_name, "--scope", "user"),
            environment=environment,
        )
        if remove_result.returncode == 0:
            reporter("已清理旧的邮件助手用户级 MCP 条目，正在注册新版本。")
        elif _is_missing_result(remove_result):
            reporter("未发现旧的邮件助手用户级 MCP 条目（首次安装正常），继续注册。")
        else:
            raise RegistrationError(
                _redacted_failure("claude mcp remove", remove_result)
            )

        add_arguments = (
            "mcp",
            "add",
            "--transport",
            "stdio",
            "--scope",
            "user",
            server_name,
            "--",
            str(powershell_executable),
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-File",
            str(server_script),
        )
        add_result = _run_claude(
            claude_executable,
            claude_prefix,
            add_arguments,
            environment=environment,
        )
        if add_result.returncode != 0:
            raise RegistrationError(_redacted_failure("claude mcp add", add_result))

        _verify_entry(
            user_config,
            server_name=server_name,
            powershell_executable=powershell_executable,
            server_script=server_script,
        )
        get_result = _run_claude(
            claude_executable,
            claude_prefix,
            ("mcp", "get", server_name),
            environment=environment,
        )
        if get_result.returncode != 0:
            raise RegistrationError(_redacted_failure("claude mcp get", get_result))
        reporter("Claude Code 用户级邮件助手 MCP 注册、配置核对和读取验证已完成。")
    except Exception as exc:
        try:
            _restore_user_config(user_config, backup, was_present=was_present)
        except Exception as rollback_exc:
            raise RegistrationError(
                f"{exc}; ROLLBACK FAILED: {rollback_exc}"
            ) from rollback_exc
        raise RegistrationError(f"{exc}; Claude user configuration restored") from exc


def unregister_user_mcp(
    *,
    claude_executable: str,
    claude_prefix: Sequence[str],
    server_name: str,
    user_config: Path,
    backup: Path,
    reporter: Reporter = print,
    environment: Mapping[str, str] | None = None,
) -> None:
    _validate_inputs(
        claude_executable=claude_executable,
        claude_prefix=claude_prefix,
        server_name=server_name,
        powershell_executable=None,
        server_script=None,
        user_config=user_config,
        backup=backup,
    )
    was_present = user_config.is_file()
    if was_present:
        _atomic_copy(user_config, backup, overwrite=False)
    try:
        remove_result = _run_claude(
            claude_executable,
            claude_prefix,
            ("mcp", "remove", server_name, "--scope", "user"),
            environment=environment,
        )
        if remove_result.returncode != 0 and not _is_missing_result(remove_result):
            raise RegistrationError(
                _redacted_failure("claude mcp remove", remove_result)
            )
        if remove_result.returncode != 0:
            # Claude 2.1.84 creates a small default config file even when the
            # requested entry is absent. Restore the original bytes in that
            # case so an idempotent uninstall has no side effect.
            _restore_user_config(user_config, backup, was_present=was_present)
            reporter("未发现邮件助手用户级 MCP 条目（已经是移除状态）。")
            return

        _verify_absent(user_config, server_name)
        get_result = _run_claude(
            claude_executable,
            claude_prefix,
            ("mcp", "get", server_name),
            environment=environment,
        )
        if get_result.returncode == 0:
            # ``mcp get`` without a scope can resolve a project/local entry
            # with the same name after the user entry has been removed.  The
            # user-scope truth is the parsed config above; a successful get in
            # this case is harmless and must not make uninstall roll back.
            reporter(
                "Claude Code 用户级邮件助手 MCP 已移除；其他作用域的同名条目未修改。"
            )
        elif not _is_missing_result(get_result):
            raise RegistrationError(
                "claude mcp get did not confirm that the user-scoped entry is absent"
            )
        else:
            reporter("Claude Code 用户级邮件助手 MCP 已移除并核对。")
    except Exception as exc:
        try:
            _restore_user_config(user_config, backup, was_present=was_present)
        except Exception as rollback_exc:
            raise RegistrationError(
                f"{exc}; ROLLBACK FAILED: {rollback_exc}"
            ) from rollback_exc
        raise RegistrationError(f"{exc}; Claude user configuration restored") from exc


def verify_user_mcp(
    *,
    server_name: str,
    powershell_executable: Path,
    server_script: Path,
    user_config: Path,
) -> None:
    _validated_server_name(server_name)
    _regular_file(powershell_executable, "PowerShell executable")
    _regular_file(server_script, "mail MCP launcher")
    _validate_config_path(user_config, "Claude user configuration")
    _verify_entry(
        user_config,
        server_name=server_name,
        powershell_executable=powershell_executable,
        server_script=server_script,
    )


_FAKE_CLAUDE_SOURCE = textwrap.dedent(
    r'''
    import json
    import os
    import sys
    from pathlib import Path

    args = sys.argv[1:]
    config = Path(os.environ["FAKE_CLAUDE_CONFIG"])
    events = Path(os.environ["FAKE_CLAUDE_EVENTS"])
    events.parent.mkdir(parents=True, exist_ok=True)
    with events.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(args) + "\n")

    def load():
        if not config.exists():
            return {}
        return json.loads(config.read_text(encoding="utf-8"))

    def save(payload):
        config.parent.mkdir(parents=True, exist_ok=True)
        config.write_text(json.dumps(payload, sort_keys=True) + "\n", encoding="utf-8")

    if args[:2] == ["mcp", "remove"]:
        name = args[2]
        payload = load()
        servers = payload.setdefault("mcpServers", {})
        if name not in servers:
            print(f"No user-scoped MCP server found with name: {name}", file=sys.stderr)
            save(payload)
            raise SystemExit(1)
        del servers[name]
        save(payload)
        raise SystemExit(0)

    if args[:2] == ["mcp", "add"]:
        if os.environ.get("FAKE_CLAUDE_FAIL_ADD") == "1":
            print("simulated add failure", file=sys.stderr)
            raise SystemExit(7)
        separator = args.index("--")
        scope_index = args.index("--scope")
        name = args[scope_index + 2]
        command = args[separator + 1]
        command_arguments = args[separator + 2 :]
        payload = load()
        payload.setdefault("mcpServers", {})[name] = {
            "type": "stdio",
            "command": (
                "wrong.exe"
                if os.environ.get("FAKE_CLAUDE_WRONG_ENTRY") == "1"
                else command
            ),
            "args": command_arguments,
            "env": {},
        }
        save(payload)
        if os.environ.get("FAKE_CLAUDE_ADD_STDERR") == "1":
            sys.stderr.buffer.write("模拟的非致命警告 ✓\n".encode("utf-8"))
        raise SystemExit(0)

    if args[:2] == ["mcp", "get"]:
        name = args[2]
        if name not in load().get("mcpServers", {}):
            print(f"No MCP server found with name: {name}", file=sys.stderr)
            raise SystemExit(1)
        if os.environ.get("FAKE_CLAUDE_FAIL_GET") == "1":
            print("simulated get failure", file=sys.stderr)
            raise SystemExit(8)
        raise SystemExit(0)

    print("unexpected fake Claude arguments", args, file=sys.stderr)
    raise SystemExit(9)
    ''').lstrip()


def self_test() -> None:
    """Exercise the transaction and all failure rollback branches offline."""
    with tempfile.TemporaryDirectory(prefix="mail-user-mcp-self-test-") as value:
        root = Path(value)
        fake_cli = root / "fake_claude.py"
        fake_cli.write_text(_FAKE_CLAUDE_SOURCE, encoding="utf-8")
        powershell = root / "powershell.exe"
        powershell.write_bytes(b"MZ")
        server_script = root / "run-server.ps1"
        server_script.write_text("# fixture\n", encoding="utf-8")
        user_config = root / ".claude.json"
        events = root / "events.jsonl"
        environment = dict(os.environ)
        environment.update(
            {
                "FAKE_CLAUDE_CONFIG": str(user_config),
                "FAKE_CLAUDE_EVENTS": str(events),
                "FAKE_CLAUDE_ADD_STDERR": "1",
            }
        )
        quiet: Reporter = lambda _message: None

        original = b'{"unrelated":{"keep":true}}\r\n'
        user_config.write_bytes(original)
        backup = root / "first.bak"
        register_user_mcp(
            claude_executable=sys.executable,
            claude_prefix=(str(fake_cli),),
            server_name="mail-mcp",
            powershell_executable=powershell,
            server_script=server_script,
            user_config=user_config,
            backup=backup,
            reporter=quiet,
            environment=environment,
        )
        if backup.read_bytes() != original:
            raise RegistrationError("existing config was not backed up byte-for-byte")
        verify_user_mcp(
            server_name="mail-mcp",
            powershell_executable=powershell,
            server_script=server_script,
            user_config=user_config,
        )
        events_payload = [json.loads(line) for line in events.read_text().splitlines()]
        expected_prefix = [
            ["mcp", "remove", "mail-mcp", "--scope", "user"],
            [
                "mcp",
                "add",
                "--transport",
                "stdio",
                "--scope",
                "user",
                "mail-mcp",
                "--",
                str(powershell),
                "-NoLogo",
                "-NoProfile",
                "-NonInteractive",
                "-File",
                str(server_script),
            ],
            ["mcp", "get", "mail-mcp"],
        ]
        if events_payload[:3] != expected_prefix:
            raise RegistrationError(
                f"unexpected Claude user-scope command sequence: {events_payload[:3]!r}"
            )

        failed_original = b'{"keep":"before-add-failure"}\n'
        user_config.write_bytes(failed_original)
        failure_environment = dict(environment)
        failure_environment["FAKE_CLAUDE_FAIL_ADD"] = "1"
        try:
            register_user_mcp(
                claude_executable=sys.executable,
                claude_prefix=(str(fake_cli),),
                server_name="mail-mcp",
                powershell_executable=powershell,
                server_script=server_script,
                user_config=user_config,
                backup=root / "add-failure.bak",
                reporter=quiet,
                environment=failure_environment,
            )
        except RegistrationError:
            pass
        else:
            raise RegistrationError("simulated add failure unexpectedly succeeded")
        if user_config.read_bytes() != failed_original:
            raise RegistrationError("add failure did not restore the original config")

        user_config.unlink()
        get_failure_environment = dict(environment)
        get_failure_environment["FAKE_CLAUDE_FAIL_GET"] = "1"
        try:
            register_user_mcp(
                claude_executable=sys.executable,
                claude_prefix=(str(fake_cli),),
                server_name="mail-mcp",
                powershell_executable=powershell,
                server_script=server_script,
                user_config=user_config,
                backup=root / "get-failure.bak",
                reporter=quiet,
                environment=get_failure_environment,
            )
        except RegistrationError:
            pass
        else:
            raise RegistrationError("simulated get failure unexpectedly succeeded")
        if user_config.exists():
            raise RegistrationError("new config was not removed after get failure")

        # Re-register, then prove unregister and idempotent removal preserve
        # unrelated bytes (the exact behavior needed by uninstall rollback).
        register_user_mcp(
            claude_executable=sys.executable,
            claude_prefix=(str(fake_cli),),
            server_name="mail-mcp",
            powershell_executable=powershell,
            server_script=server_script,
            user_config=user_config,
            backup=root / "second.bak",
            reporter=quiet,
            environment=environment,
        )
        unregister_user_mcp(
            claude_executable=sys.executable,
            claude_prefix=(str(fake_cli),),
            server_name="mail-mcp",
            user_config=user_config,
            backup=root / "remove.bak",
            reporter=quiet,
            environment=environment,
        )
        if user_config.exists() and "mail-mcp" in _read_config(user_config).get(
            "mcpServers", {}
        ):
            raise RegistrationError("unregister left the mail assistant entry behind")

        if not any(item[:2] == ["mcp", "add"] for item in events_payload):
            raise RegistrationError("self-test did not execute claude mcp add")


def _common_parser_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--claude-executable", required=True)
    parser.add_argument("--claude-prefix", action="append", default=[])
    parser.add_argument("--server-name", required=True)
    parser.add_argument("--user-config", required=True, type=Path)
    parser.add_argument("--backup", required=True, type=Path)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    register_parser = subparsers.add_parser("register")
    _common_parser_arguments(register_parser)
    register_parser.add_argument("--powershell-executable", required=True, type=Path)
    register_parser.add_argument("--server-script", required=True, type=Path)

    unregister_parser = subparsers.add_parser("unregister")
    _common_parser_arguments(unregister_parser)

    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("--server-name", required=True)
    verify_parser.add_argument("--user-config", required=True, type=Path)
    verify_parser.add_argument("--powershell-executable", required=True, type=Path)
    verify_parser.add_argument("--server-script", required=True, type=Path)

    subparsers.add_parser("self-test")
    return parser


def main() -> int:
    arguments = build_parser().parse_args()
    try:
        if arguments.command == "self-test":
            self_test()
            print("MAIL CLAUDE USER MCP REGISTRATION SELF-TEST PASSED")
        elif arguments.command == "register":
            register_user_mcp(
                claude_executable=arguments.claude_executable,
                claude_prefix=arguments.claude_prefix,
                server_name=arguments.server_name,
                powershell_executable=arguments.powershell_executable,
                server_script=arguments.server_script,
                user_config=arguments.user_config,
                backup=arguments.backup,
            )
        elif arguments.command == "unregister":
            unregister_user_mcp(
                claude_executable=arguments.claude_executable,
                claude_prefix=arguments.claude_prefix,
                server_name=arguments.server_name,
                user_config=arguments.user_config,
                backup=arguments.backup,
            )
        else:
            verify_user_mcp(
                server_name=arguments.server_name,
                powershell_executable=arguments.powershell_executable,
                server_script=arguments.server_script,
                user_config=arguments.user_config,
            )
            print("MAIL CLAUDE USER MCP REGISTRATION VERIFIED")
    except (OSError, RegistrationError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    _configure_standard_streams()
    raise SystemExit(main())
