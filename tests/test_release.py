from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import re
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
            self.assertEqual("0.7.0", plugin["version"])
            self.assertEqual("local-unverified", metadata["release_channel"])
            self.assertFalse(metadata["target_mcp_smoke_tested"])
            self.assertEqual(len(release.EXACT_FILES) + 1, len(internal["files"]))

    def test_internal_verifier_rejects_corruption_and_local_gate_claim(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive, _ = release.build_release(ROOT, root)
            with zipfile.ZipFile(archive) as bundle:
                bundle.extractall(root / "extracted")
            plugin_root = root / "extracted" / release.BUNDLE_NAME
            verifier.verify(
                plugin_root,
                require_windows_gate=False,
                allow_python_runtime=False,
            )
            with self.assertRaises(verifier.VerificationError):
                verifier.verify(
                    plugin_root,
                    require_windows_gate=True,
                    allow_python_runtime=False,
                )
            (plugin_root / "README.md").write_text("corrupted\n", encoding="utf-8")
            with self.assertRaises(verifier.VerificationError):
                verifier.verify(
                    plugin_root,
                    require_windows_gate=False,
                    allow_python_runtime=False,
                )

    def test_windows_gate_metadata_requires_exact_host_runner_and_commit(self) -> None:
        commit = "a" * 40
        with mock.patch.object(release, "normalized_system", return_value="windows"), mock.patch.object(
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

    def test_lifecycle_scripts_use_shared_atomic_moves_and_no_runtime_rediscovery(self) -> None:
        lifecycle_files = [
            ROOT / "scripts" / "install.ps1",
            ROOT / "scripts" / "uninstall.ps1",
            ROOT / "scripts" / "windows-lifecycle-common.ps1",
        ]
        combined = "\n".join(path.read_text(encoding="utf-8") for path in lifecycle_files)
        self.assertNotIn("Move-Item", combined)
        self.assertIn("[IO.Directory]::Move", combined)
        self.assertIn("[IO.FileShare]::None", combined)
        self.assertIn("DIRECTORY MOVE RETRY", combined)
        self.assertIn("Move-CoremailDirectoryAtomically", combined)
        self.assertIn("Diagnostics are best-effort", combined)

        common = (ROOT / "scripts" / "windows-lifecycle-common.ps1").read_text(
            encoding="utf-8"
        )
        self.assertIn("2> $nativeErrorPath", common)
        self.assertNotIn("2>&1", common)
        self.assertIn("$global:LASTEXITCODE = $null", common)
        self.assertIn("Invoke-CoremailClaudeChecked", common)
        self.assertIn("DISABLE_AUTOUPDATER", common)
        common_normalized = " ".join(common.lower().split())
        self.assertIn("assert-coremaildefaultclaudeconfigdirectory", common_normalized)
        self.assertIn("claude_config_dir", common_normalized)
        self.assertIn("[environment]::systemdirectory", common_normalized)
        self.assertIn("-verb runas", common_normalized)
        self.assertIn(".claude\\skills\\coremail-controller", common_normalized)
        self.assertIn("isaccountsid", common_normalized)
        self.assertIn("/grant {1} /l /q", common_normalized)
        self.assertIn("*{0}:(oi)(ci)m", common_normalized)
        self.assertNotIn(" /t ", common_normalized)
        self.assertNotIn("/reset", common_normalized)
        self.assertNotIn("takeown", common_normalized)

        launcher = (ROOT / "mcp" / "run-server.ps1").read_text(encoding="utf-8")
        setup = (ROOT / "scripts" / "setup-account.ps1").read_text(encoding="utf-8")
        installer = (ROOT / "scripts" / "install.ps1").read_text(encoding="utf-8")
        self.assertIn("python-runtime.json", launcher)
        self.assertIn("executable_sha256", launcher)
        self.assertIn("-B -I", launcher)
        self.assertNotIn("COREMAIL_PYTHON", launcher)
        self.assertNotIn("COREMAIL_PYTHON", setup)
        self.assertNotIn("COREMAIL_PYTHON", installer)
        stale_exit_code_check = re.compile(
            r"(?im)smoke-mcp\.ps1[^\r\n]*\r?\n[ \t]*if\s*\(\$LASTEXITCODE"
        )
        self.assertIsNone(stale_exit_code_check.search(installer))
        workflow = (ROOT / ".github" / "workflows" / "windows-release-gate.yml").read_text(
            encoding="utf-8"
        )
        self.assertIsNone(stale_exit_code_check.search(workflow))
        for lifecycle_directory in (
            "$activationStagingDirectory",
            "$backupDirectory",
            "$failedDirectory",
            "$lifecycleLockPath",
            "$settingsPath",
        ):
            self.assertIn(
                f"-Path {lifecycle_directory}",
                installer,
            )
        self.assertIn("Assert-CoremailSafeDescendantPath", installer)
        self.assertIn("Assert-CoremailSafeDescendantPath", setup)
        uninstaller = (ROOT / "scripts" / "uninstall.ps1").read_text(encoding="utf-8")
        self.assertIn("-Path $disabledRoot", uninstaller)

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

    def test_windows_gate_uses_real_native_and_npm_claude_under_standard_users(self) -> None:
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
        self.assertIn("claude_code_version: \"2.1.246\"", normalized)
        self.assertIn("claude_npm_node_version: \"24.19.0\"", normalized)
        self.assertIn("@anthropic-ai/claude-code@$env:claude_code_version", normalized)
        self.assertNotIn("--ignore-scripts", normalized)
        self.assertIn("--windows-gate", normalized)
        self.assertIn("--source-commit $env:github_sha", normalized)
        self.assertIn("-scenarioname native", normalized)
        self.assertIn("-scenarioname npm", normalized)
        self.assertLess(
            normalized.index("tests\\smoke-mcp.ps1"),
            normalized.index("scripts\\build-release.py"),
        )
        self.assertLess(
            normalized.index("run-windows-release-gate.ps1"),
            normalized.index("actions/upload-artifact@v7"),
        )
        self.assertIn("actions/download-artifact@v8", normalized)
        self.assertIn("needs: windows-powershell-51", normalized)
        self.assertIn("github.event_name == 'push'", normalized)

        lifecycle_normalized = " ".join(lifecycle.lower().split())
        self.assertIn("expectedidentitysid", lifecycle_normalized)
        self.assertIn("windowsbuiltinrole]::administrator", lifecycle_normalized)
        self.assertIn("parser]::parsefile", lifecycle_normalized)
        self.assertIn("add-type -typedefinition", lifecycle_normalized)
        self.assertIn("after_credential_write", lifecycle_normalized)
        self.assertIn("directory move retry", lifecycle_normalized)
        self.assertIn("legacy acl repair requested", lifecycle_normalized)
        self.assertIn("legacy acl repair recovered mode=release-gate-handshake", lifecycle_normalized)
        self.assertIn("unsupported-custom-claude-root", lifecycle_normalized)
        self.assertIn("automatic permission repair was disabled", lifecycle_normalized)
        self.assertIn("s-1-5-18", lifecycle_normalized)
        self.assertIn("s-1-5-32-544", lifecycle_normalized)
        self.assertIn("plugin', 'validate'", lifecycle_normalized)
        self.assertIn("plugin', 'list', '--json'", lifecycle_normalized)
        self.assertIn("npmbinkind", lifecycle_normalized)
        self.assertIn("legacy-node-resolver-ok", lifecycle_normalized)
        self.assertIn("legacy-stderr-is-separated", lifecycle_normalized)
        self.assertIn("intentionally-absent-claude.exe", lifecycle_normalized)
        self.assertIn("$installeduninstaller", lifecycle_normalized)
        self.assertNotIn("-checkconnection", lifecycle_normalized)

        orchestrator_normalized = " ".join(orchestrator.lower().split())
        self.assertIn("#requires -runasadministrator", orchestrator_normalized)
        self.assertIn("new-localuser", orchestrator_normalized)
        self.assertIn("-credential $credential", orchestrator_normalized)
        self.assertIn("-loaduserprofile", orchestrator_normalized)
        self.assertIn("remove-localuser", orchestrator_normalized)
        self.assertNotIn("add-localgroupmember", orchestrator_normalized)
        self.assertIn("sourcepackageroot", orchestrator_normalized)
        self.assertNotIn(
            "copy-item -literalpath $claudesourceroot -destination $claudefixtureroot -recurse",
            orchestrator_normalized,
        )

        uninstaller = (ROOT / "scripts" / "uninstall.ps1").read_text(encoding="utf-8")
        self.assertIn("TrimStart().StartsWith('[')", uninstaller)
        self.assertLess(
            uninstaller.index("UNINSTALL no active plugin found"),
            uninstaller.index("$claudeInvocation = Resolve-ClaudeCodeInvocation"),
        )

    def test_release_refuses_to_overwrite_by_default(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            release.build_release(ROOT, output)
            with self.assertRaises(release.ReleaseError):
                release.build_release(ROOT, output)


if __name__ == "__main__":
    unittest.main()
