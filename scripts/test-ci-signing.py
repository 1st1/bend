#!/usr/bin/env python3
"""Check credential lifecycle without touching a real keychain or Apple service."""
import base64
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("ci_signing", Path(__file__).with_name("ci-signing.py"))
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


# @lat: [[lat.md/tests/build-tests#CI signing credential lifecycle]]
class SigningTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="bend-ci-signing-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.calls = []
        environment = {
            "GITHUB_ACTIONS": "true", "RUNNER_TEMP": str(self.root),
            "GITHUB_ENV": str(self.root / "environment"),
            "BEND_CERTIFICATE_P12_BASE64": base64.b64encode(b"test certificate").decode() + "\n",
            "BEND_CERTIFICATE_PASSWORD": "test password",
            "BEND_NOTARY_KEY_P8": "test private key",
            "BEND_NOTARY_KEY_ID": "KEYID", "BEND_NOTARY_ISSUER_ID": "ISSUER",
        }
        self.addCleanup(patch.stopall)
        patch.dict(os.environ, environment).start()
        self.command = patch.object(signing, "run", side_effect=self.fake_run).start()

    def fake_run(self, *args):
        self.calls.append(args)
        if args == ("security", "list-keychains", "-d", "user"):
            return '"/original/login.keychain-db"'
        if args[:2] == ("security", "create-keychain"):
            Path(args[-1]).touch()
        return ""

    def test_setup_and_cleanup(self):
        signing.setup()
        state = signing.state_path()
        directory = Path(json.loads(state.read_text())["directory"])
        self.assertEqual(state.stat().st_mode & 0o777, 0o600)
        self.assertEqual(directory.stat().st_mode & 0o777, 0o700)
        self.assertFalse((directory / "certificate.p12").exists())
        self.assertFalse((directory / "notary.p8").exists())
        self.assertIn("BEND_NOTARY_KEYCHAIN=", (self.root / "environment").read_text())
        signing.cleanup()
        self.assertFalse(state.exists())
        self.assertFalse(directory.exists())
        self.assertIn(("security", "list-keychains", "-d", "user", "-s", "/original/login.keychain-db"), self.calls)

    def test_cleanup_after_failed_notarization_setup(self):
        def fail_notary(*args):
            self.fake_run(*args)
            if args[0] == "xcrun":
                raise subprocess.CalledProcessError(1, args)
            return '"/original/login.keychain-db"' if args == ("security", "list-keychains", "-d", "user") else ""
        self.command.side_effect = fail_notary
        with self.assertRaises(subprocess.CalledProcessError):
            signing.setup()
        directory = Path(json.loads(signing.state_path().read_text())["directory"])
        self.assertTrue((directory / "notary.p8").exists())
        self.command.side_effect = self.fake_run
        signing.cleanup()
        self.assertFalse(directory.exists())

    def test_missing_secrets_fail_before_keychain_changes(self):
        with patch.dict(os.environ, {"BEND_CERTIFICATE_PASSWORD": ""}):
            with self.assertRaisesRegex(ValueError, "BEND_CERTIFICATE_PASSWORD"):
                signing.setup()
        self.assertEqual(self.calls, [])
        self.assertFalse(signing.state_path().exists())

    def test_cleanup_removes_files_even_if_keychain_command_fails(self):
        signing.setup()
        directory = Path(json.loads(signing.state_path().read_text())["directory"])
        self.command.side_effect = subprocess.CalledProcessError(1, ["security"])
        with self.assertRaisesRegex(ValueError, "Signing cleanup failed"):
            signing.cleanup()
        self.assertFalse(directory.exists())
        self.assertFalse(signing.state_path().exists())


if __name__ == "__main__":
    unittest.main()
