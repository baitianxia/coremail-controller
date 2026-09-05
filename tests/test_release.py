from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


release = load_module("build_release", ROOT / "scripts" / "build-release.py")
verifier = load_module("verify_release", ROOT / "scripts" / "verify-release.py")
registrar = load_module(
    "register_claude_user_mcp", ROOT / "scripts" / "register_claude_user_mcp.py"
)


class ReleaseTests(unittest.TestCase):
    def test_local_archive_is_visibly_unverified_allowlisted_and_hashed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive, sidecar = release.build_release(ROOT, Path(temporary))
            self.assertEqual(release.LOCAL_ARCHIVE_NAME, archive.name)
            self.assertIn("UNVERIFIED", archive.name)
            expected_hash = hashlib.sha256(archive.read_bytes()).hexdigest()
            self.assertEqual(
                f"{expected_hash}  {release.LOCAL_ARCHIVE_NAME}\n".encode("ascii"),
                sidecar.read_bytes(),
            )
            with zipfile.ZipFile(archive) as bundle:
                names = set(bundle.namelist())
                expected = {
                    (Path(release.BUNDLE_NAME) / relative).as_posix()
                    for relative in release.EXACT_FILES + release.GENERATED_FILES
                }
                self.assertEqual(expected, names)
                self.assertFalse(any("__pycache__" in name for name in names))
                self.assertFalse(any("config.json" in name.lower() for name in names))
                plugin = json.loads(
                    bundle.read(
                        f"{release.BUNDLE_NAME}/.claude-plugin/plugin.json"
                    ).decode("utf-8")
                )
                metadata = json.loads(
                    bundle.read(
                        f"{release.BUNDLE_NAME}/BUILD-METADATA.json"
                    ).decode("utf-8")
                )
                internal = json.loads(
                    bundle.read(
                        f"{release.BUNDLE_NAME}/FILE-MANIFEST.json"
                    ).decode("utf-8")
                )
            self.assertEqual("0.8.0", plugin["version"])
            self.assertEqual("local-unverified", metadata["release_channel"])
            self.assertFalse(metadata["target_mcp_smoke_tested"])
            self.assertEqual(len(release.EXACT_FILES) + 1, len(internal["files"]))
            self.assertIn("SKILL.md", release.EXACT_FILES)
            self.assertIn("scripts/register_claude_user_mcp.py", release.EXACT_FILES)

    def test_internal_verifier_rejects_corruption_and_local_gate_claim(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive, _ = release.build_release(ROOT, root)
            with zipfile.ZipFile(archive) as bundle:
                bundle.extractall(root / "extracted")
            package_root = root / "extracted" / release.BUNDLE_NAME
            verifier.verify(
                package_root,
                require_windows_gate=False,
                allow_python_runtime=False,
            )
            with self.assertRaises(verifier.VerificationError):
                verifier.verify(
                    package_root,
                    require_windows_gate=True,
                    allow_python_runtime=False,
                )
            (package_root / "README.md").write_text("corrupted\n", encoding="utf-8")
            with self.assertRaises(verifier.VerificationError):
                verifier.verify(
                    package_root,
                    require_windows_gate=False,
                    allow_python_runtime=False,
                )

    def test_windows_gate_metadata_requires_exact_host_runner_and_commit(self) -> None:
        commit = "a" * 40
        with mock.patch.object(
            release, "normalized_system", return_value="windows"
        ), mock.patch.object(
            release, "normalized_machine", return_value="x64"
        ), mock.patch.dict(
            os.environ,
            {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted"},
            clear=False,
        ):
            metadata = release.build_metadata(windows_gate=True, source_commit=commit)
        self.assertEqual("windows-native-gated", metadata["release_channel"])
        self.assertTrue(metadata["target_mcp_smoke_tested"])
        self.assertFalse(metadata["cross_built"])
        self.assertEqual(commit, metadata["source_commit"])
        with self.assertRaises(release.ReleaseError):
            release.build_metadata(windows_gate=True, source_commit="short")

    def test_python_descriptor_records_the_actual_executable_and_hash(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "python-runtime.json"
            result = subprocess.run(
                [
                    sys.executable,
                    "-B",
                    "-I",
                    str(ROOT / "mcp" / "describe-python.py"),
                    "--output",
                    str(output),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(0, result.returncode, msg=result.stderr)
            payload = json.loads(output.read_text(encoding="utf-8"))
            executable = Path(payload["executable"])
            self.assertTrue(executable.is_file())
            self.assertEqual(
                hashlib.sha256(executable.read_bytes()).hexdigest(),
                payload["executable_sha256"],
            )
            self.assertGreaterEqual(payload["version_info"][:2], [3, 10])

    def test_staged_config_validator_runs_in_isolated_python(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            config = Path(temporary) / "config.json"
            config.write_text(
                json.dumps(
                    {
                        "transport": "windows_simple_mapi",
                        "username": "gate@example.invalid",
                        "allowed_from": ["gate@example.invalid"],
                        "sent_copy_mode": "none",
                        "attachment_roots": [],
                    }
                ),
                encoding="utf-8",
            )
            completed = subprocess.run(
                [
                    sys.executable,
                    "-B",
                    "-I",
                    str(ROOT / "mcp" / "validate-config.py"),
                    str(config),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(0, completed.returncode, msg=completed.stderr)

    def test_user_scope_registration_self_test_and_cli_sequence(self) -> None:
        completed = subprocess.run(
            [
                sys.executable,
                "-B",
                "-I",
                str(ROOT / "scripts" / "register_claude_user_mcp.py"),
                "self-test",
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(0, completed.returncode, msg=completed.stderr)
        self.assertIn("SELF-TEST PASSED", completed.stdout)

    def test_lifecycle_scripts_use_atomic_moves_and_direct_user_mcp(self) -> None:
        lifecycle_files = [
            ROOT / "scripts" / "install.ps1",
            ROOT / "scripts" / "uninstall.ps1",
            ROOT / "scripts" / "windows-lifecycle-common.ps1",
        ]
        combined = "\n".join(path.read_text(encoding="utf-8") for path in lifecycle_files)
        registrar_source = (ROOT / "scripts" / "register_claude_user_mcp.py").read_text(
            encoding="utf-8"
        )
        self.assertNotIn("Move-Item", combined)
        self.assertIn("[IO.Directory]::Move", combined)
        self.assertIn("[IO.FileShare]::None", combined)
        self.assertIn("DIRECTORY MOVE RETRY", combined)
        self.assertIn("Move-CoremailDirectoryAtomically", combined)
        self.assertIn("Diagnostics are best-effort", combined)
        self.assertIn("register_claude_user_mcp.py", combined)
        self.assertIn("--scope", registrar_source)
        self.assertNotIn("Assert-CoremailClaudeMinimumVersion", combined)
        self.assertNotIn("2.1.157", combined)
        self.assertNotIn("plugin validate", combined.lower())
        self.assertNotIn("plugin enable", combined.lower())
        self.assertNotIn("plugin list", combined.lower())

        common = (ROOT / "scripts" / "windows-lifecycle-common.ps1").read_text(
            encoding="utf-8"
        )
        self.assertIn("2> $nativeErrorPath", common)
        self.assertNotIn("2>&1", common)
        self.assertIn("$global:LASTEXITCODE = $null", common)
        self.assertIn("Invoke-CoremailClaudeChecked", common)
        self.assertIn("Resolve-CoremailClaudeUserConfigPath", common)
        self.assertIn("CLAUDE_CONFIG_DIR", common)
        self.assertIn("Assert-CoremailSafeLocalPath", common)
        self.assertIn("DISABLE_AUTOUPDATER", common)
        normalized_common = " ".join(common.lower().split())
        self.assertIn("[environment]::systemdirectory", normalized_common)
        self.assertIn("-verb runas", normalized_common)
        self.assertIn(".claude\\skills\\coremail-controller", normalized_common)
        self.assertIn("isaccountsid", normalized_common)
        self.assertIn("/grant {1} /l /q", normalized_common)
        self.assertIn("*{0}:(oi)(ci)m", normalized_common)
        self.assertNotIn(" /t ", normalized_common)
        self.assertNotIn("/reset", normalized_common)
        self.assertNotIn("takeown", normalized_common)

        launcher = (ROOT / "mcp" / "run-server.ps1").read_text(encoding="utf-8")
        setup = (ROOT / "scripts" / "setup-account.ps1").read_text(encoding="utf-8")
        installer = (ROOT / "scripts" / "install.ps1").read_text(encoding="utf-8")
        self.assertIn("python-runtime.json", launcher)
        self.assertIn("executable_sha256", launcher)
        self.assertIn("-B -I", launcher)
        self.assertNotIn("COREMAIL_PYTHON", launcher)
        self.assertNotIn("COREMAIL_PYTHON", setup)
        self.assertNotIn("COREMAIL_PYTHON", installer)
        self.assertIn("$claudeUserConfigSnapshot", installer)
        self.assertIn("Restore-CoremailFileSnapshot", installer)
        self.assertIsNone(
            re.search(
                r"(?im)smoke-mcp\.ps1[^\r\n]*\r?\n[ \t]*if\s*\(\$LASTEXITCODE",
                installer,
            )
        )
        for lifecycle_directory in (
            "$activationStagingDirectory",
            "$backupDirectory",
            "$failedDirectory",
            "$lifecycleLockPath",
        ):
            self.assertIn(f"-Path {lifecycle_directory}", installer)
        self.assertIn("Assert-CoremailSafeDescendantPath", installer)
        self.assertIn("Assert-CoremailSafeDescendantPath", setup)
        uninstaller = (ROOT / "scripts" / "uninstall.ps1").read_text(encoding="utf-8")
        self.assertIn("-Path $disabledRoot", uninstaller)
        self.assertIn("unregister", uninstaller)

    def test_account_configuration_is_validate_then_credential_then_atomic_publish(self) -> None:
        setup = (ROOT / "scripts" / "setup-account.ps1").read_text(encoding="utf-8")
        validation = setup.index("Staged account configuration validation")
        credential = setup.index("Write-CoremailCredential")
        publication = setup.index("Publish-CoremailFileAtomically")
        self.assertLess(validation, credential)
        self.assertLess(credential, publication)
        self.assertIn("Remove-CoremailCredential", setup)
        self.assertIn("after_credential_write", setup)
        credential_helper = (ROOT / "scripts" / "windows-credential.ps1").read_text(
            encoding="utf-8"
        )
        self.assertIn(
            "System.Runtime.InteropServices.ComTypes.FILETIME", credential_helper
        )
        self.assertIn("CredDeleteW", credential_helper)

    def test_old_claude_is_supported_by_capability_not_version_floor(self) -> None:
        installer = (ROOT / "scripts" / "install.ps1").read_text(encoding="utf-8")
        common = (ROOT / "scripts" / "windows-lifecycle-common.ps1").read_text(
            encoding="utf-8"
        )
        self.assertNotIn("Assert-CoremailClaudeMinimumVersion", installer)
        self.assertNotIn("Assert-CoremailClaudeMinimumVersion", common)
        self.assertNotIn("2.1.157", installer + common)
        self.assertIn("mcp', '--help'", installer)
        self.assertIn("register_claude_user_mcp.py", installer)
        self.assertIn("mcp", registrar.__doc__.lower())

    def test_claude_version_probe_is_informational_and_restores_environment(self) -> None:
        shell = (
            shutil.which("powershell.exe")
            or shutil.which("powershell")
            or shutil.which("pwsh")
        )
        if shell is None:
            self.skipTest("PowerShell is not available on this host")
        common_path = str(ROOT / "scripts" / "windows-lifecycle-common.ps1").replace(
            "'", "''"
        )
        shell_path = str(Path(shell).resolve()).replace("'", "''")
        command = f"""
$ErrorActionPreference = 'Stop'
. '{common_path}'
$env:DISABLE_AUTOUPDATER = 'before-auto'
$env:DISABLE_UPDATES = 'before-updates'
$probe = [pscustomobject]@{{
    Executable = '{shell_path}'
    # Wrap the command in a script block so PowerShell does not echo the
    # probe's appended ``--version`` argument as a second line.
    Prefix = [string[]]@(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-Command',
        "& {{ [Console]::Write('custom-build-label') }}"
    )
}}
$observed = Get-CoremailClaudeVersion -Invocation $probe -Label 'unit informational'
if ($null -ne $observed.Version -or $observed.Text.Trim() -ne 'custom-build-label') {{
    throw 'The non-semantic version result was not preserved as informational text.'
}}
if ($env:DISABLE_AUTOUPDATER -ne 'before-auto' -or
    $env:DISABLE_UPDATES -ne 'before-updates') {{
    throw 'Claude update environment was not restored.'
}}
Write-Output 'PASS'
"""
        completed = subprocess.run(
            [shell, "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", command],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(0, completed.returncode, msg=completed.stderr + completed.stdout)
        self.assertIn("PASS", completed.stdout)

    def test_windows_gate_mentions_exact_legacy_fixture_as_supported(self) -> None:
        workflow = (ROOT / ".github" / "workflows" / "windows-release-gate.yml").read_text(
            encoding="utf-8"
        )
        lifecycle = (ROOT / "tests" / "windows-lifecycle.ps1").read_text(
            encoding="utf-8"
        )
        orchestrator = (ROOT / "tests" / "run-windows-release-gate.ps1").read_text(
            encoding="utf-8"
        )
        normalized = " ".join(workflow.lower().split())
        self.assertIn("runs-on: windows-2022", normalized)
        self.assertIn('claude_code_version: "2.1.246"', normalized)
        self.assertIn('claude_legacy_code_version: "2.1.84"', normalized)
        self.assertIn('claude_npm_node_version: "24.19.0"', normalized)
        self.assertIn("@anthropic-ai/claude-code@$env:claude_code_version", normalized)
        self.assertNotIn("--ignore-scripts", normalized)
        self.assertIn("--windows-gate", normalized)
        self.assertIn("--source-commit $env:github_sha", normalized)
        self.assertIn("-scenarioname native", normalized)
        self.assertIn("-scenarioname npm", normalized)
        self.assertEqual(2, normalized.count("& $orchestrator"))
        self.assertIn("claude 2.1.84 user-scope registration", normalized)
        self.assertIn("register_claude_user_mcp.py", normalized)
        self.assertIn(
            "if (-not $?) { throw 'source mcp smoke test failed.' }",
            normalized,
        )
        self.assertIn("actions/download-artifact@v8", normalized)
        self.assertIn("needs: windows-powershell-51", normalized)
        self.assertLess(
            normalized.index("tests\\smoke-mcp.ps1"),
            normalized.index("scripts\\build-release.py"),
        )
        self.assertLess(
            normalized.index("run-windows-release-gate.ps1"),
            normalized.index("actions/upload-artifact@v7"),
        )
        self.assertNotIn("unsupported legacy claude fixture", normalized)
        self.assertNotIn("2\\.1\\.157 or newer", normalized)

        lifecycle_normalized = " ".join(lifecycle.lower().split())
        for required in (
            "expectedidentitysid",
            "windowsbuiltinrole]::administrator",
            "parser]::parsefile",
            "add-type -typedefinition",
            "after_credential_write",
            "directory move retry",
            "legacy acl repair requested",
            "legacy acl repair recovered mode=release-gate-handshake",
            "relative-custom-claude-root",
            "automatic permission repair was disabled",
            "s-1-5-18",
            "s-1-5-32-544",
            "mcp', '--help'",
            "npmbinkind",
            "legacy-node-resolver-ok",
            "legacy-stderr-is-separated",
            "intentionally-absent-claude.exe",
            "$installeduninstaller",
            "assert-usermcpregistered",
            "assert-usermcpabsent",
            "userconfighashbeforelegacydenial",
            "permissionrepairrequestpath",
            "permissionrepaircompletepath",
        ):
            self.assertIn(required, lifecycle_normalized)
        self.assertNotIn("plugin', 'validate'", lifecycle_normalized)
        self.assertNotIn("plugin', 'list'", lifecycle_normalized)
        self.assertNotIn("-checkconnection", lifecycle_normalized)

        orchestrator_normalized = " ".join(orchestrator.lower().split())
        for required in (
            "#requires -runasadministrator",
            "$psversiontable.psedition -ne 'desktop'",
            "$psversiontable.psversion.major -ne 5",
            "new-localuser",
            "-credential $credential",
            "-loaduserprofile",
            "remove-localuser",
            "complete-coremailgatepermissionrepair",
            "[environment]::systemdirectory",
            "'icacls.exe'",
            "'/grant'",
            "'/l'",
            "'/q'",
            "$expectedsid.isaccountsid()",
            "$permissionrepairhandled = $true",
            "$processhandle = $process.handle",
            "$null -eq $processexitcode",
        ):
            self.assertIn(required, orchestrator_normalized)
        self.assertLess(
            orchestrator.index("$processHandle = $process.Handle"),
            orchestrator.index("while (-not $process.HasExited)"),
        )
        self.assertNotIn("add-localgroupmember", orchestrator_normalized)
        self.assertNotRegex(orchestrator_normalized, r"(?:^|\s)move-item(?:\s|$)")
        self.assertNotIn("'/t'", orchestrator_normalized)
        self.assertNotIn("/reset", orchestrator_normalized)
        self.assertNotIn("takeown", orchestrator_normalized)

        uninstaller = (ROOT / "scripts" / "uninstall.ps1").read_text(encoding="utf-8")
        self.assertLess(
            uninstaller.index("UNINSTALL no active Coremail package found"),
            uninstaller.index("Resolve-CoremailClaudeUserConfigPath"),
        )
        self.assertLess(
            uninstaller.index("Resolve-CoremailClaudeUserConfigPath"),
            uninstaller.index("Enter-CoremailLifecycleLock"),
        )

    def test_release_refuses_to_overwrite_by_default(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            release.build_release(ROOT, output)
            with self.assertRaises(release.ReleaseError):
                release.build_release(ROOT, output)


if __name__ == "__main__":
    unittest.main()
