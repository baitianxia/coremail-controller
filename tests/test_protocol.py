from __future__ import annotations

import json
import re
import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SERVER = ROOT / "mcp" / "server.py"


class ProtocolTests(unittest.TestCase):
    def test_claude_plugin_layout_and_mcp_path_are_portable(self) -> None:
        manifest = json.loads((ROOT / ".claude-plugin" / "plugin.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["name"], "coremail-controller")
        self.assertEqual(manifest["version"], "0.7.0")

        coremail_skill = (ROOT / "skills" / "coremail" / "SKILL.md").read_text(encoding="utf-8")
        browser_skill = (ROOT / "skills" / "web-to-coremail" / "SKILL.md").read_text(encoding="utf-8")
        self.assertTrue(coremail_skill.startswith("---\nname: coremail\n"))
        self.assertTrue(browser_skill.startswith("---\nname: web-to-coremail\n"))
        mcp_config = json.loads((ROOT / ".mcp.json").read_text(encoding="utf-8"))
        self.assertEqual(set(mcp_config["mcpServers"]), {"coremail-windows"})
        server = mcp_config["mcpServers"]["coremail-windows"]
        self.assertEqual(server["command"].lower(), "powershell.exe")
        self.assertIn("${CLAUDE_PLUGIN_ROOT}/mcp/run-server.ps1", server["args"])
        self.assertNotIn("Bypass", server["args"])
        self.assertNotIn(str(ROOT), json.dumps(mcp_config))
        for launcher in ("INSTALL.cmd", "CONFIGURE-ACCOUNT.cmd", "UNINSTALL.cmd"):
            self.assertTrue((ROOT / launcher).is_file())

        installer = (ROOT / "scripts" / "install.ps1").read_text(encoding="utf-8")
        self.assertIn("plugin-backups", installer)
        self.assertNotIn("skills\\coremail-controller.backup", installer)
        self.assertIn("tests\\smoke-mcp.ps1", installer)
        launch_sources = installer + (ROOT / "INSTALL.cmd").read_text(encoding="utf-8")
        launch_sources += (ROOT / "tests" / "smoke-mcp.ps1").read_text(encoding="utf-8")
        self.assertNotIn("ExecutionPolicy", launch_sources)

    def test_browser_orchestration_is_isolated_and_send_gated(self) -> None:
        browser_skill = (ROOT / "skills" / "web-to-coremail" / "SKILL.md").read_text(encoding="utf-8")
        normalized = " ".join(browser_skill.lower().split())
        self.assertIn("do not install, configure, wrap, or merge", normalized)
        self.assertIn("do not send email bodies", normalized)
        self.assertIn("never fetch additional browser content", normalized)
        self.assertIn("确认发送", browser_skill)

        implementation = "\n".join(
            path.read_text(encoding="utf-8")
            for directory in (ROOT / "mcp", ROOT / "scripts")
            for path in directory.glob("*")
            if path.suffix in {".py", ".ps1"}
        ).lower()
        self.assertNotIn("coremail_password", implementation)
        for browser_dependency in ("playwright", "puppeteer", "selenium", "chromedriver"):
            self.assertNotIn(browser_dependency, implementation)

    def test_initialize_tools_and_offline_status(self) -> None:
        requests = [
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {},
                    "clientInfo": {"name": "unit-test", "version": "1"},
                },
            },
            {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
            {
                "jsonrpc": "2.0",
                "id": 3,
                "method": "tools/call",
                "params": {"name": "coremail_connection_status", "arguments": {}},
            },
        ]
        payload = "".join(json.dumps(item, ensure_ascii=False) + "\n" for item in requests)
        completed = subprocess.run(
            [sys.executable, "-I", str(SERVER)],
            input=payload,
            text=True,
            encoding="utf-8",
            capture_output=True,
            timeout=10,
            check=True,
        )
        responses = [json.loads(line) for line in completed.stdout.splitlines() if line.strip()]
        self.assertEqual([response["id"] for response in responses], [1, 2, 3])
        self.assertEqual(responses[0]["result"]["serverInfo"]["name"], "coremail-headless")
        self.assertEqual(responses[0]["result"]["serverInfo"]["version"], "0.7.0")
        names = {tool["name"] for tool in responses[1]["result"]["tools"]}
        self.assertEqual(len(names), 10)
        self.assertIn("coremail_discover_local", names)
        self.assertIn("coremail_send_prepared", names)
        self.assertFalse(any("click" in name or "screenshot" in name or "window" in name for name in names))
        status = json.loads(responses[2]["result"]["content"][0]["text"])
        self.assertFalse(status["coremail_client_interface_selected"])
        self.assertFalse(status["coremail_client_interface_used"])
        self.assertFalse(status["coremail_ui_automation_used"])
        self.assertIn("client_interface", status)

    def test_windows_stdio_bom_is_tolerated_only_at_stream_start(self) -> None:
        initialize = {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "bom-test", "version": "1"},
            },
        }
        later_bom_request = {
            "jsonrpc": "2.0",
            "id": 2,
            "method": "ping",
            "params": {},
        }
        completed = subprocess.run(
            [sys.executable, "-I", str(SERVER)],
            input=(
                "\ufeff"
                + json.dumps(initialize)
                + "\n\ufeff"
                + json.dumps(later_bom_request)
                + "\n"
            ),
            text=True,
            encoding="utf-8",
            capture_output=True,
            timeout=10,
            check=True,
        )
        responses = [json.loads(line) for line in completed.stdout.splitlines()]
        self.assertEqual(1, responses[0]["id"])
        self.assertEqual(
            "coremail-headless", responses[0]["result"]["serverInfo"]["name"]
        )
        self.assertIsNone(responses[1]["id"])
        self.assertEqual(-32700, responses[1]["error"]["code"])

    def test_implementation_has_no_desktop_automation_primitives(self) -> None:
        sources = "\n".join(
            path.read_text(encoding="utf-8")
            for path in (ROOT / "mcp").glob("*")
            if path.suffix in {".py", ".ps1"}
        ).lower()
        for forbidden in ("uiautomationclient", "setcursorpos", "sendinput", "copyfromscreen", "mapi_dialog"):
            self.assertNotIn(forbidden, sources)

    def test_setup_is_interface_first_and_password_fallback_is_secure(self) -> None:
        setup = (ROOT / "scripts" / "setup-account.ps1").read_text(encoding="utf-8").lower()
        mapi = (ROOT / "mcp" / "windows_mapi.py").read_text(encoding="utf-8").lower()
        self.assertIn("mapilogon", mapi)
        self.assertIn("null profile/password and zero flags", mapi)
        self.assertIn("self._logon(0, none, none, 0, 0", " ".join(mapi.split()))
        self.assertIn("'--probe-json'", setup)
        self.assertIn("get-pinnedpythonruntime", setup)
        self.assertIn("windows_simple_mapi", setup)
        self.assertIn("imap_smtp", setup)
        self.assertIn("-assecurestring", setup)
        self.assertIn("windows credential manager", setup)
        self.assertNotIn("mapi_dialog", setup)

    def test_credential_writer_uses_unambiguous_filetime_type(self) -> None:
        setup = (ROOT / "scripts" / "windows-credential.ps1").read_text(
            encoding="utf-8"
        ).lower()
        self.assertIn(
            "public system.runtime.interopservices.comtypes.filetime lastwritten;",
            setup,
        )
        self.assertNotIn("public filetime lastwritten;", setup)

    def test_install_activation_does_not_import_temporary_directory_acl(self) -> None:
        installer = (ROOT / "scripts" / "install.ps1").read_text(encoding="utf-8").lower()
        normalized = " ".join(installer.split())
        self.assertIn("plugin-staging", normalized)
        self.assertIn(
            "copy-coremailplugintree -source $sourceroot -destination $activationplugin",
            normalized,
        )
        self.assertIn(
            "move-coremaildirectoryatomically ` -source $activationplugin ` -destination $targetroot",
            normalized,
        )
        self.assertIsNone(re.search(r"(?<![a-z])move-item\b", normalized))

    def test_uninstall_fails_closed_on_lock_or_acl_denial(self) -> None:
        uninstaller = (ROOT / "scripts" / "uninstall.ps1").read_text(encoding="utf-8").lower()
        common = (ROOT / "scripts" / "windows-lifecycle-common.ps1").read_text(
            encoding="utf-8"
        ).lower()
        lifecycle = uninstaller + common
        self.assertIn("unauthorizedaccessexception", lifecycle)
        self.assertIn("io.ioexception", lifecycle)
        self.assertIn("ambiguous state", common)
        self.assertIn("guid", uninstaller)
        self.assertIn("fileshare]::none", common)
        self.assertIn("move-coremaildirectoryatomically", uninstaller)
        self.assertIsNone(re.search(r"(?<![a-z])move-item\b", lifecycle))
        self.assertNotIn("takeown", uninstaller)
        self.assertNotIn("icacls", uninstaller)

    def test_python_version_probe_avoids_native_output_and_quote_loss(self) -> None:
        probe = ROOT / "mcp" / "check-python.py"
        completed = subprocess.run(
            [sys.executable, "-I", str(probe)],
            text=True,
            capture_output=True,
            timeout=10,
            check=False,
        )
        self.assertEqual(completed.returncode, 0)
        self.assertEqual(completed.stdout, "")
        self.assertEqual(completed.stderr, "")

        sources = [
            (ROOT / "scripts" / "install.ps1").read_text(encoding="utf-8"),
            (ROOT / "mcp" / "run-server.ps1").read_text(encoding="utf-8"),
        ]
        for source in sources:
            normalized = " ".join(source.lower().split())
            self.assertNotIn("-c 'import sys", normalized)
            self.assertNotIn('print("%d.%d"', normalized)
        installer = " ".join(sources[0].lower().split())
        launcher = " ".join(sources[1].lower().split())
        self.assertIn("describe-python.py", installer)
        self.assertIn("python-runtime.json", launcher)
        self.assertIn("executable_sha256", launcher)
        self.assertNotIn("coremail_python", launcher)

        smoke = (ROOT / "tests" / "smoke-mcp.ps1").read_text(encoding="utf-8")
        self.assertNotIn("StandardInputEncoding", smoke)


if __name__ == "__main__":
    unittest.main()
