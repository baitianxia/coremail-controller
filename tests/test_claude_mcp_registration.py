from __future__ import annotations

import importlib.util
import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "coremail_user_mcp_registration",
    ROOT / "scripts" / "register_claude_user_mcp.py",
)
assert SPEC and SPEC.loader
registration = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(registration)


class UserMcpRegistrationTests(unittest.TestCase):
    def _paths(self, root: Path) -> tuple[Path, Path, Path, Path, Path]:
        powershell = root / "powershell.exe"
        powershell.write_bytes(b"MZ")
        server_script = root / "run-server.ps1"
        server_script.write_text("# fixture\n", encoding="utf-8")
        user_config = root / ".claude.json"
        backup = root / "config.backup"
        return powershell, server_script, user_config, backup, root / "events.jsonl"

    @staticmethod
    def _write_entry(
        user_config: Path, powershell: Path, server_script: Path
    ) -> None:
        payload = (
            json.loads(user_config.read_text(encoding="utf-8"))
            if user_config.exists()
            else {}
        )
        payload.setdefault("mcpServers", {})["coremail-controller"] = {
            "type": "stdio",
            "command": str(powershell),
            "args": [
                "-NoLogo",
                "-NoProfile",
                "-NonInteractive",
                "-File",
                str(server_script),
            ],
            "env": {},
        }
        user_config.write_bytes(
            (json.dumps(payload, sort_keys=True) + "\n").encode("utf-8")
        )

    def test_registers_exact_user_scope_sequence_and_preserves_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            powershell, server_script, user_config, backup, _ = self._paths(root)
            original = b'{"unrelated":{"keep":true}}\r\n'
            user_config.write_bytes(original)
            calls: list[tuple[str, ...]] = []

            def runner(_executable, _prefix, arguments, **_kwargs):
                calls.append(tuple(arguments))
                if arguments[1] == "add":
                    self._write_entry(user_config, powershell, server_script)
                return subprocess.CompletedProcess(arguments, 0, "", "warning\n")

            with mock.patch.object(registration, "_run_claude", side_effect=runner):
                registration.register_user_mcp(
                    claude_executable="claude.exe",
                    claude_prefix=(),
                    server_name="coremail-controller",
                    powershell_executable=powershell,
                    server_script=server_script,
                    user_config=user_config,
                    backup=backup,
                    reporter=lambda _message: None,
                )

            self.assertEqual(
                [
                    ("mcp", "remove", "coremail-controller", "--scope", "user"),
                    (
                        "mcp",
                        "add",
                        "--transport",
                        "stdio",
                        "--scope",
                        "user",
                        "coremail-controller",
                        "--",
                        str(powershell),
                        "-NoLogo",
                        "-NoProfile",
                        "-NonInteractive",
                        "-File",
                        str(server_script),
                    ),
                    ("mcp", "get", "coremail-controller"),
                ],
                calls,
            )
            self.assertEqual(original, backup.read_bytes())
            self.assertEqual({"keep": True}, json.loads(user_config.read_text())["unrelated"])

    def test_missing_remove_and_success_stderr_are_nonfatal(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            powershell, server_script, user_config, backup, _ = self._paths(root)
            results = iter(
                (
                    subprocess.CompletedProcess(
                        [], 1, "", "No user-scoped MCP server found with name: coremail-controller"
                    ),
                    subprocess.CompletedProcess([], 0, "", "warning"),
                    subprocess.CompletedProcess([], 0, "server", ""),
                )
            )

            def runner(_executable, _prefix, arguments, **_kwargs):
                result = next(results)
                if arguments[1] == "add":
                    self._write_entry(user_config, powershell, server_script)
                return result

            with mock.patch.object(registration, "_run_claude", side_effect=runner):
                registration.register_user_mcp(
                    claude_executable="claude.exe",
                    claude_prefix=(),
                    server_name="coremail-controller",
                    powershell_executable=powershell,
                    server_script=server_script,
                    user_config=user_config,
                    backup=backup,
                    reporter=lambda _message: None,
                )
            self.assertFalse(backup.exists())

    def test_remove_failure_and_add_failure_restore_original_config(self) -> None:
        for failure_command in ("remove", "add"):
            with self.subTest(failure_command=failure_command), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                powershell, server_script, user_config, backup, _ = self._paths(root)
                original = b'{"keep":"before"}\r\n'
                user_config.write_bytes(original)

                def runner(_executable, _prefix, arguments, **_kwargs):
                    if arguments[1] == "remove" and failure_command == "remove":
                        user_config.write_text('{"partial":true}\n', encoding="utf-8")
                        return subprocess.CompletedProcess(arguments, 5, "", "permission denied")
                    if arguments[1] == "add" and failure_command == "add":
                        return subprocess.CompletedProcess(arguments, 7, "", "add failed")
                    return subprocess.CompletedProcess(arguments, 0, "", "")

                with mock.patch.object(registration, "_run_claude", side_effect=runner):
                    with self.assertRaises(registration.RegistrationError):
                        registration.register_user_mcp(
                            claude_executable="claude.exe",
                            claude_prefix=(),
                            server_name="coremail-controller",
                            powershell_executable=powershell,
                            server_script=server_script,
                            user_config=user_config,
                            backup=backup,
                            reporter=lambda _message: None,
                        )
                self.assertEqual(original, user_config.read_bytes())
                self.assertEqual(original, backup.read_bytes())

    def test_wrong_entry_and_get_failure_restore_or_remove_config(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            powershell, server_script, user_config, backup, _ = self._paths(root)
            original = b'{"keep":"before"}\n'
            user_config.write_bytes(original)

            def wrong_entry_runner(_executable, _prefix, arguments, **_kwargs):
                if arguments[1] == "add":
                    user_config.write_text(
                        '{"mcpServers":{"coremail-controller":{"type":"stdio","command":"wrong.exe","args":[]}}}\n',
                        encoding="utf-8",
                    )
                return subprocess.CompletedProcess(arguments, 0, "", "")

            with mock.patch.object(
                registration, "_run_claude", side_effect=wrong_entry_runner
            ):
                with self.assertRaisesRegex(
                    registration.RegistrationError, "does not match"
                ):
                    registration.register_user_mcp(
                        claude_executable="claude.exe",
                        claude_prefix=(),
                        server_name="coremail-controller",
                        powershell_executable=powershell,
                        server_script=server_script,
                        user_config=user_config,
                        backup=backup,
                        reporter=lambda _message: None,
                    )
            self.assertEqual(original, user_config.read_bytes())

            user_config.unlink()

            def get_failure_runner(_executable, _prefix, arguments, **_kwargs):
                if arguments[1] == "add":
                    self._write_entry(user_config, powershell, server_script)
                if arguments[1] == "get":
                    return subprocess.CompletedProcess(arguments, 8, "", "get failed")
                return subprocess.CompletedProcess(arguments, 0, "", "")

            with mock.patch.object(
                registration, "_run_claude", side_effect=get_failure_runner
            ):
                with self.assertRaises(registration.RegistrationError):
                    registration.register_user_mcp(
                        claude_executable="claude.exe",
                        claude_prefix=(),
                        server_name="coremail-controller",
                        powershell_executable=powershell,
                        server_script=server_script,
                        user_config=user_config,
                        backup=root / "get.backup",
                        reporter=lambda _message: None,
                    )
            self.assertFalse(user_config.exists())

    def test_unregistration_is_idempotent_and_preserves_unrelated_config(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            _, _, user_config, backup, _ = self._paths(root)
            original = b'{"customSetting":"preserve-me"}\r\n'
            user_config.write_bytes(original)
            calls: list[tuple[str, ...]] = []

            def runner(_executable, _prefix, arguments, **_kwargs):
                calls.append(tuple(arguments))
                if arguments[1] == "remove":
                    return subprocess.CompletedProcess(
                        arguments, 1, "", "No MCP server found with name: coremail-controller"
                    )
                raise AssertionError("get must not run after an absent remove")

            with mock.patch.object(registration, "_run_claude", side_effect=runner):
                registration.unregister_user_mcp(
                    claude_executable="claude.exe",
                    claude_prefix=(),
                    server_name="coremail-controller",
                    user_config=user_config,
                    backup=backup,
                    reporter=lambda _message: None,
                )
            self.assertEqual(original, user_config.read_bytes())
            self.assertEqual(1, len(calls))

    def test_unregistration_allows_same_name_in_another_scope(self) -> None:
        """`mcp get` may report a project entry after the user entry is gone."""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            powershell, server_script, user_config, backup, _ = self._paths(root)
            self._write_entry(user_config, powershell, server_script)

            def runner(_executable, _prefix, arguments, **_kwargs):
                if arguments[1] == "remove":
                    payload = json.loads(user_config.read_text(encoding="utf-8"))
                    del payload["mcpServers"]["coremail-controller"]
                    user_config.write_text(json.dumps(payload), encoding="utf-8")
                    return subprocess.CompletedProcess(arguments, 0, "", "")
                if arguments[1] == "get":
                    # A project/local same-name entry can make an unscoped get
                    # succeed even though the user entry was removed.
                    return subprocess.CompletedProcess(arguments, 0, "project", "")
                raise AssertionError(f"unexpected command: {arguments}")

            with mock.patch.object(registration, "_run_claude", side_effect=runner):
                registration.unregister_user_mcp(
                    claude_executable="claude.exe",
                    claude_prefix=(),
                    server_name="coremail-controller",
                    user_config=user_config,
                    backup=backup,
                    reporter=lambda _message: None,
                )
            self.assertNotIn(
                "coremail-controller",
                json.loads(user_config.read_text(encoding="utf-8")).get(
                    "mcpServers", {}
                ),
            )

    def test_narrow_code_page_does_not_break_unicode_status(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fake_cli = root / "fake_claude.py"
            fake_cli.write_text(registration._FAKE_CLAUDE_SOURCE, encoding="utf-8")
            powershell, server_script, user_config, backup, _ = self._paths(root)
            environment = dict(os.environ)
            environment.update(
                {
                    "FAKE_CLAUDE_CONFIG": str(user_config),
                    "FAKE_CLAUDE_EVENTS": str(root / "events.jsonl"),
                    "FAKE_CLAUDE_ADD_STDERR": "1",
                    "PYTHONIOENCODING": "cp1252:strict",
                }
            )
            result = subprocess.run(
                [
                    sys.executable,
                    str(ROOT / "scripts" / "register_claude_user_mcp.py"),
                    "register",
                    "--claude-executable",
                    sys.executable,
                    "--claude-prefix",
                    str(fake_cli),
                    "--server-name",
                    "coremail-controller",
                    "--powershell-executable",
                    str(powershell),
                    "--server-script",
                    str(server_script),
                    "--user-config",
                    str(user_config),
                    "--backup",
                    str(backup),
                ],
                env=environment,
                capture_output=True,
                check=False,
                timeout=30,
            )
            self.assertEqual(0, result.returncode, result.stderr.decode("ascii"))
            self.assertIn(b"\\u672a\\u53d1\\u73b0", result.stdout)

    def test_path_chain_rejects_a_linked_ancestor(self) -> None:
        if not hasattr(os, "symlink"):
            self.skipTest("symbolic links are unavailable")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            real = root / "real"
            real.mkdir()
            linked = root / "linked"
            try:
                linked.symlink_to(real, target_is_directory=True)
            except (OSError, NotImplementedError):
                self.skipTest("symbolic links are unavailable")
            # Simulate the Windows reparse metadata check on a POSIX test host.
            # The important assertion is that validation continues past the
            # first existing descendant and inspects every ancestor.
            with mock.patch.object(
                registration,
                "_is_reparse_metadata",
                side_effect=lambda metadata: stat.S_ISLNK(metadata.st_mode),
            ):
                with self.assertRaises(registration.RegistrationError):
                    registration._validate_config_path(
                        linked / "nested" / ".claude.json", "config"
                    )

    def test_native_command_never_inserts_a_shell(self) -> None:
        command = registration._native_command(
            r"C:\Tools\claude.exe", (), ("mcp", "get", "coremail-controller")
        )
        self.assertEqual(
            [r"C:\Tools\claude.exe", "mcp", "get", "coremail-controller"], command
        )
        self.assertNotIn("cmd.exe", " ".join(command).lower())


if __name__ == "__main__":
    unittest.main()
