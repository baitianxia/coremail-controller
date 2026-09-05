from __future__ import annotations

import hashlib
import importlib.util
import json
import os
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
registrar = load_module("register_claude_user_mcp", ROOT / "scripts" / "register_claude_user_mcp.py")


class ReleaseTests(unittest.TestCase):
    def test_local_archive_is_visibly_unverified_allowlisted_and_hashed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive, sidecar = release.build_release(ROOT, Path(temporary))
            self.assertEqual(release.LOCAL_ARCHIVE_NAME, archive.name)
            self.assertIn("UNVERIFIED", archive.name)
            digest = hashlib.sha256(archive.read_bytes()).hexdigest()
            self.assertEqual(f"{digest}  {archive.name}\n".encode("ascii"), sidecar.read_bytes())
            with zipfile.ZipFile(archive) as bundle:
                names = set(bundle.namelist())
                expected = {(Path(release.BUNDLE_NAME) / relative).as_posix() for relative in release.EXACT_FILES + release.GENERATED_FILES}
                self.assertEqual(expected, names)
                self.assertFalse(any("__pycache__" in name for name in names))
                plugin = json.loads(bundle.read(f"{release.BUNDLE_NAME}/.claude-plugin/plugin.json"))
                metadata = json.loads(bundle.read(f"{release.BUNDLE_NAME}/BUILD-METADATA.json"))
            self.assertEqual("0.9.0", plugin["version"])
            self.assertEqual("local-unverified", metadata["release_channel"])
            self.assertFalse(metadata["target_mcp_smoke_tested"])
            self.assertIn("scripts/register_claude_user_mcp.py", release.EXACT_FILES)

    def test_internal_verifier_rejects_corruption_and_local_gate_claim(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive, _ = release.build_release(ROOT, root)
            with zipfile.ZipFile(archive) as bundle:
                bundle.extractall(root / "extracted")
            package_root = root / "extracted" / release.BUNDLE_NAME
            verifier.verify(package_root, require_windows_gate=False, allow_python_runtime=False)
            with self.assertRaises(verifier.VerificationError):
                verifier.verify(package_root, require_windows_gate=True, allow_python_runtime=False)
            (package_root / "README.md").write_text("corrupted\n", encoding="utf-8")
            with self.assertRaises(verifier.VerificationError):
                verifier.verify(package_root, require_windows_gate=False, allow_python_runtime=False)

    def test_windows_gate_metadata_requires_exact_host_runner_and_commit(self) -> None:
        commit = "a" * 40
        with mock.patch.object(release, "normalized_system", return_value="windows"), mock.patch.object(
            release, "normalized_machine", return_value="x64"
        ), mock.patch.dict(os.environ, {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted"}, clear=False):
            metadata = release.build_metadata(windows_gate=True, source_commit=commit)
        self.assertEqual("windows-native-gated", metadata["release_channel"])
        self.assertTrue(metadata["target_mcp_smoke_tested"])
        self.assertEqual(commit, metadata["source_commit"])
        with self.assertRaises(release.ReleaseError):
            release.build_metadata(windows_gate=True, source_commit="short")

    def test_python_descriptor_records_the_actual_executable_and_hash(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "python-runtime.json"
            result = subprocess.run(
                [sys.executable, "-B", "-I", str(ROOT / "mcp" / "describe-python.py"), "--output", str(output)],
                check=False, capture_output=True, text=True,
            )
            self.assertEqual(0, result.returncode, msg=result.stderr)
            payload = json.loads(output.read_text(encoding="utf-8"))
            executable = Path(payload["executable"])
            self.assertTrue(executable.is_file())
            self.assertEqual(hashlib.sha256(executable.read_bytes()).hexdigest(), payload["executable_sha256"])
            self.assertGreaterEqual(payload["version_info"][:2], [3, 10])

    def test_staged_config_validator_runs_in_isolated_python(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            config = Path(temporary) / "config.json"
            config.write_text(json.dumps({"transport": "windows_simple_mapi", "username": "gate@example.invalid", "allowed_from": ["gate@example.invalid"], "sent_copy_mode": "none", "attachment_roots": []}), encoding="utf-8")
            completed = subprocess.run([sys.executable, "-B", "-I", str(ROOT / "mcp" / "validate-config.py"), str(config)], check=False, capture_output=True, text=True)
            self.assertEqual(0, completed.returncode, msg=completed.stderr)

    def test_user_scope_registration_self_test(self) -> None:
        completed = subprocess.run([sys.executable, "-B", "-I", str(ROOT / "scripts" / "register_claude_user_mcp.py"), "self-test"], check=False, capture_output=True, text=True)
        self.assertEqual(0, completed.returncode, msg=completed.stderr)
        self.assertIn("SELF-TEST PASSED", completed.stdout)

    def test_lifecycle_is_localappdata_only_and_never_elevates(self) -> None:
        lifecycle_files = [ROOT / "scripts" / name for name in ("install.ps1", "uninstall.ps1", "configure-account.ps1", "windows-lifecycle-common.ps1")]
        combined = "\n".join(path.read_text(encoding="utf-8") for path in lifecycle_files)
        normalized = " ".join(combined.lower().split())
        self.assertIn("localappdata", normalized)
        self.assertIn("coremailcontroller", normalized)
        self.assertIn("releases", normalized)
        self.assertIn("move-coremaildirectoryatomically", normalized)
        self.assertIn("[io.directory]::move", normalized)
        self.assertIn("[io.fileshare]::none", normalized)
        self.assertIn("register_claude_user_mcp.py", normalized)
        self.assertNotIn(".claude\\skills", normalized)
        self.assertNotIn("plugin-backups", normalized)
        self.assertNotIn("plugin-staging", normalized)
        self.assertNotIn("runas", normalized)
        self.assertNotIn("icacls", normalized)
        self.assertNotIn("read-host", normalized)
        self.assertNotIn("plugin validate", normalized)
        self.assertNotIn("plugin enable", normalized)
        self.assertNotIn("plugin list", normalized)
        self.assertNotIn("Assert-CoremailClaudeMinimumVersion", combined)

    def test_lifecycle_scripts_use_pinned_runtime_and_transactional_config(self) -> None:
        installer = (ROOT / "scripts" / "install.ps1").read_text(encoding="utf-8")
        uninstaller = (ROOT / "scripts" / "uninstall.ps1").read_text(encoding="utf-8")
        launcher = (ROOT / "mcp" / "run-server.ps1").read_text(encoding="utf-8")
        self.assertIn("python-runtime.json", launcher)
        self.assertIn("executable_sha256", launcher)
        self.assertIn("Assert-CoremailRelease", installer)
        self.assertIn("Save-CoremailFileSnapshot", installer)
        self.assertIn("Restore-CoremailFileSnapshot", installer)
        self.assertIn("releases", installer)
        self.assertIn("unregister", uninstaller)
        self.assertIn("retained", uninstaller.lower())
        self.assertNotIn("COREMAIL_PYTHON", installer + uninstaller + launcher)
        self.assertNotIn("Move-Item", installer + uninstaller)

    def test_account_configuration_is_validate_then_credential_then_atomic_publish(self) -> None:
        setup = (ROOT / "scripts" / "setup-account.ps1").read_text(encoding="utf-8")
        self.assertLess(setup.index("Staged account configuration validation"), setup.index("Write-CoremailCredential"))
        self.assertLess(setup.index("Write-CoremailCredential"), setup.index("Publish-CoremailFileAtomically"))
        self.assertIn("Remove-CoremailCredential", setup)
        credential_helper = (ROOT / "scripts" / "windows-credential.ps1").read_text(encoding="utf-8")
        self.assertIn("System.Runtime.InteropServices.ComTypes.FILETIME", credential_helper)
        self.assertIn("CredDeleteW", credential_helper)

    def test_old_claude_is_supported_by_capability_not_version_floor(self) -> None:
        installer = (ROOT / "scripts" / "install.ps1").read_text(encoding="utf-8")
        uninstaller = (ROOT / "scripts" / "uninstall.ps1").read_text(encoding="utf-8")
        common = (ROOT / "scripts" / "windows-lifecycle-common.ps1").read_text(encoding="utf-8")
        self.assertNotIn("Assert-CoremailClaudeMinimumVersion", installer + common)
        self.assertNotIn("2.1.157", installer + common)
        self.assertIn("mcp', '--help'", installer)
        self.assertIn("[switch]$QuietOnSuccess", common)
        self.assertIn("-QuietOnSuccess", installer)
        self.assertIn("-QuietOnSuccess", uninstaller)
        self.assertIn("register_claude_user_mcp.py", installer)

    def test_release_refuses_to_overwrite_by_default(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            release.build_release(ROOT, output)
            with self.assertRaises(release.ReleaseError):
                release.build_release(ROOT, output)


if __name__ == "__main__":
    unittest.main()
