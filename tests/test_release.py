from __future__ import annotations

import hashlib
import importlib.util
import json
import re
import tempfile
import unittest
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "build_release", ROOT / "scripts" / "build-release.py"
)
assert SPEC and SPEC.loader
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


class ReleaseTests(unittest.TestCase):
    def test_release_is_allowlisted_rooted_and_hashed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive, sidecar = release.build_release(ROOT, Path(temporary))
            expected_hash = hashlib.sha256(archive.read_bytes()).hexdigest()
            self.assertEqual(
                f"{expected_hash}  {release.ARCHIVE_NAME}\n",
                sidecar.read_text(encoding="ascii"),
            )
            with zipfile.ZipFile(archive) as bundle:
                names = set(bundle.namelist())
                expected = {
                    (Path(release.BUNDLE_NAME) / relative).as_posix()
                    for relative in release.EXACT_FILES
                }
                self.assertEqual(expected, names)
                self.assertIn(
                    f"{release.BUNDLE_NAME}/INSTALL.cmd",
                    names,
                )
                self.assertFalse(any("__pycache__" in name for name in names))
                self.assertFalse(any("config.json" in name for name in names))
                manifest = json.loads(
                    bundle.read(
                        f"{release.BUNDLE_NAME}/.claude-plugin/plugin.json"
                    ).decode("utf-8")
                )
                self.assertEqual("0.5.3", manifest["version"])

    def test_release_contains_the_windows_lifecycle_gate(self) -> None:
        self.assertIn("tests/windows-lifecycle.ps1", release.EXACT_FILES)
        self.assertIn("tests/run-windows-release-gate.ps1", release.EXACT_FILES)
        with tempfile.TemporaryDirectory() as temporary:
            archive, _ = release.build_release(ROOT, Path(temporary))
            with zipfile.ZipFile(archive) as bundle:
                lifecycle_path = (
                    f"{release.BUNDLE_NAME}/tests/windows-lifecycle.ps1"
                )
                lifecycle = bundle.read(lifecycle_path).decode("utf-8")
                orchestrator_path = (
                    f"{release.BUNDLE_NAME}/tests/run-windows-release-gate.ps1"
                )
                orchestrator = bundle.read(orchestrator_path).decode("utf-8")

        normalized = " ".join(lifecycle.lower().split())
        self.assertIn("#requires -version 5.1", normalized)
        self.assertIn("$env:github_actions -ne 'true'", normalized)
        self.assertIn("$env:runner_environment -ne 'github-hosted'", normalized)
        self.assertIn("$psversiontable.psedition -ne 'desktop'", normalized)
        self.assertIn("windowsbuiltinrole]::administrator", normalized)
        self.assertIn("expectedidentitysid", normalized)
        self.assertIn("parser]::parsefile", normalized)
        self.assertIn("add-type -typedefinition", normalized)
        self.assertIn("-skipconnectioncheck", normalized)
        self.assertIn("tests\\smoke-mcp.ps1", normalized)
        self.assertIn("get-filehash", normalized)
        self.assertGreaterEqual(normalized.count("-scriptpath $installer"), 3)
        self.assertGreaterEqual(normalized.count("-scriptpath $uninstaller"), 2)
        self.assertNotIn("-checkconnection", normalized)
        self.assertNotIn("read-host", normalized)
        self.assertNotIn("icacls", normalized)
        self.assertNotIn("takeown", normalized)

        setup = (ROOT / "scripts" / "setup-account.ps1").read_text(encoding="utf-8")
        credential_source = re.search(
            r"(?ms)^[ \t]*\$credentialSource[ \t]*=[ \t]*@'\r?\n"
            r"(?P<source>.*?)\r?\n'@[ \t]*$",
            setup,
        )
        self.assertIsNotNone(credential_source)
        assert credential_source is not None
        self.assertIn(
            "System.Runtime.InteropServices.ComTypes.FILETIME",
            credential_source.group("source"),
        )

        orchestrator_normalized = " ".join(orchestrator.lower().split())
        self.assertIn("#requires -runasadministrator", orchestrator_normalized)
        self.assertIn("new-localuser", orchestrator_normalized)
        self.assertIn("start-process", orchestrator_normalized)
        self.assertIn("-credential $credential", orchestrator_normalized)
        self.assertIn("-loaduserprofile", orchestrator_normalized)
        self.assertIn("-workingdirectory $gateroot", orchestrator_normalized)
        self.assertIn("remove-localuser", orchestrator_normalized)
        self.assertNotIn("add-localgroupmember", orchestrator_normalized)

    def test_ci_upload_is_ordered_after_the_windows_51_gate(self) -> None:
        workflow = (
            ROOT / ".github" / "workflows" / "windows-release-gate.yml"
        ).read_text(encoding="utf-8")
        normalized = " ".join(workflow.lower().split())
        self.assertIn("runs-on: windows-2022", normalized)
        self.assertIn("actions/checkout@v7", normalized)
        self.assertIn("actions/setup-python@v7", normalized)
        self.assertIn("python -m unittest discover -s tests -v", normalized)
        lifecycle_position = normalized.index("tests\\run-windows-release-gate.ps1")
        upload_position = normalized.index("actions/upload-artifact@v7")
        self.assertLess(lifecycle_position, upload_position)
        self.assertIn("$windowsPowerShell".lower(), normalized)
        self.assertGreaterEqual(normalized.count("get-filehash"), 2)
        self.assertIn("checksum sidecar does not match", normalized)
        self.assertIn("changed after lifecycle testing", normalized)
        self.assertIn("coremail-controller-windows-gated", normalized)

    def test_release_refuses_to_overwrite_by_default(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            release.build_release(ROOT, output)
            with self.assertRaises(release.ReleaseError):
                release.build_release(ROOT, output)


if __name__ == "__main__":
    unittest.main()
