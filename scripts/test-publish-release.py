#!/usr/bin/env python3
"""Exercise publication, partial failures, and retries without a GitHub release."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("publisher", Path(__file__).with_name("publish-release.py"))
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)


# @lat: [[tests#GitHub release publication]]
class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="bend-publication-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.directory = self.root / "assets"
        self.directory.mkdir()
        (self.root / "VERSION").write_text("0.1.1\n")
        (self.root / ".changes").mkdir()
        notes = "## v0.1.1\n\n### Fixed\n- Fixture fix.\n"
        (self.root / ".changes/v0.1.1.md").write_text(notes)
        (self.directory / "RELEASE_NOTES.md").write_text(notes)
        dmg = self.directory / "Bend-0.1.1-arm64.dmg"
        dmg.write_bytes(b"notarized dmg fixture")
        (self.directory / "SHA256SUMS").write_text(f"{publisher.digest(dmg)}  {dmg.name}\n")
        self.environment = {"GITHUB_ACTIONS": "true", "GITHUB_EVENT_NAME": "push",
                            "GITHUB_REF": "refs/heads/main", "RELEASE_VERSION": "0.1.1",
                            "GITHUB_SHA": "a" * 40, "GITHUB_RUN_ID": "123", "GITHUB_REPOSITORY": "example/bend"}
        (self.directory / "build.json").write_text(json.dumps(self.environment))
        self.addCleanup(patch.stopall)
        patch.dict(os.environ, self.environment).start()
        patch.object(publisher, "ROOT", self.root).start()
        self.reference = None
        self.release = None
        self.operations = []
        self.fail_upload = False
        self.corrupt_upload = False
        patch.object(publisher, "api", side_effect=self.api).start()
        self.upload = patch.object(publisher.subprocess, "run", side_effect=self.upload_assets).start()

    def api(self, path, method="GET", data=None, missing_ok=False):
        self.operations.append((method, path, copy.deepcopy(data)))
        if path.endswith("/git/ref/tags/v0.1.1"):
            return copy.deepcopy(self.reference)
        if path.endswith("/git/refs"):
            self.reference = {"object": {"type": "commit", "sha": data["sha"]}}
            return copy.deepcopy(self.reference)
        if path.endswith("/releases/tags/v0.1.1"):
            return copy.deepcopy(self.release)
        if path.endswith("/releases") and method == "POST":
            self.release = {**data, "id": 42, "assets": [], "html_url": "https://example.invalid/releases/v0.1.1"}
        elif path.endswith("/releases/42"):
            if method == "PATCH":
                self.release.update(data)
        else:
            raise AssertionError((path, method, data))
        return copy.deepcopy(self.release)

    def upload_assets(self, command, check):
        self.assertTrue(self.release["draft"], "Uploads may only modify a draft")
        self.assertEqual(command[:4], ["gh", "release", "upload", "v0.1.1"])
        self.assertEqual(command[-3:], ["--repo", "example/bend", "--clobber"])
        paths = list(map(Path, command[4:-3]))
        self.release["assets"] = [{"name": path.name, "size": path.stat().st_size, "state": "uploaded",
                                    "digest": "sha256:" + publisher.digest(path)} for path in paths]
        if self.fail_upload:
            self.release["assets"] = self.release["assets"][:1]
            raise subprocess.CalledProcessError(1, command)
        if self.corrupt_upload:
            self.release["assets"][0]["digest"] = "sha256:wrong"

    def test_publish_exact_commit_and_assets_then_retry_without_overwriting(self):
        publisher.publish(self.directory)
        self.assertEqual(self.reference["object"]["sha"], self.environment["GITHUB_SHA"])
        self.assertFalse(self.release["draft"])
        self.assertFalse(self.release["prerelease"])
        self.assertEqual(self.release["body"], (self.directory / "RELEASE_NOTES.md").read_text())
        self.assertEqual(len(self.release["assets"]), 4)
        self.operations.clear()
        publisher.publish(self.directory)
        self.assertEqual(self.upload.call_count, 1)
        self.assertTrue(all(method == "GET" for method, _, _ in self.operations))

    def test_failed_upload_leaves_draft_and_retry_completes(self):
        self.fail_upload = True
        with self.assertRaises(subprocess.CalledProcessError):
            publisher.publish(self.directory)
        self.assertTrue(self.release["draft"])
        self.fail_upload = False
        publisher.publish(self.directory)
        self.assertFalse(self.release["draft"])
        self.assertEqual(sum(method == "POST" and path.endswith("/git/refs")
                             for method, path, _ in self.operations), 1)

    def test_conflicting_tag_is_never_moved(self):
        self.reference = {"object": {"type": "commit", "sha": "b" * 40}}
        with self.assertRaisesRegex(ValueError, "different commit"):
            publisher.publish(self.directory)
        self.upload.assert_not_called()
        self.assertTrue(all(method == "GET" for method, _, _ in self.operations))

    def test_bad_upload_is_not_published(self):
        self.corrupt_upload = True
        with self.assertRaisesRegex(ValueError, "failed verification"):
            publisher.publish(self.directory)
        self.assertTrue(self.release["draft"])

    def test_incomplete_published_release_is_not_overwritten(self):
        publisher.publish(self.directory)
        self.release["assets"].pop()
        with self.assertRaisesRegex(ValueError, "missing or incomplete"):
            publisher.publish(self.directory)
        self.assertEqual(self.upload.call_count, 1)

    def test_invalid_inputs_fail_before_remote_mutation(self):
        for key, value in (("GITHUB_EVENT_NAME", "pull_request"), ("GITHUB_REF", "refs/heads/feature"),
                           ("GITHUB_SHA", "b" * 40), ("GITHUB_RUN_ID", "999"), ("RELEASE_VERSION", "0.2.0")):
            with self.subTest(key=key), patch.dict(os.environ, {key: value}):
                with self.assertRaises(ValueError):
                    publisher.publish(self.directory)
        self.assertEqual(self.operations, [])

    def test_tampered_dmg_and_notes_fail_before_remote_mutation(self):
        for name in ("Bend-0.1.1-arm64.dmg", "RELEASE_NOTES.md"):
            path = self.directory / name
            original = path.read_bytes()
            path.write_bytes(b"tampered")
            with self.subTest(name=name), self.assertRaises(ValueError):
                publisher.publish(self.directory)
            path.write_bytes(original)
        self.assertEqual(self.operations, [])


class APIErrorTests(unittest.TestCase):
    def test_only_404_is_treated_as_missing(self):
        with patch.object(publisher.subprocess, "run") as command:
            command.return_value = subprocess.CompletedProcess([], 1, "", "gh: Not Found (HTTP 404)")
            self.assertIsNone(publisher.api("fixture", missing_ok=True))
            for message in ("gh: Forbidden (HTTP 403)", "connection reset"):
                command.return_value = subprocess.CompletedProcess([], 1, "", message)
                with self.assertRaises(RuntimeError):
                    publisher.api("fixture", missing_ok=True)


if __name__ == "__main__":
    unittest.main()
