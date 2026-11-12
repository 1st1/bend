#!/usr/bin/env python3
import base64
from contextlib import redirect_stdout
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

spec = importlib.util.spec_from_file_location("update_feed", Path(__file__).with_name("update-feed.py"))
feed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(feed)


# @lat: [[lat.md/tests/updates-tests#Application update feed]]
class UpdateFeedTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.metadata = {"RELEASE_VERSION": "0.3.0", "BEND_BUILD_NUMBER": "125001"}
        self.save_metadata()
        (self.root / "Bend-0.3.0-arm64.dmg").write_bytes(b"archive fixture")
        (self.root / "RELEASE_NOTES.md").write_text("Fix <something> & improve tabs.")
        self.env = patch.dict(os.environ, {"GITHUB_REPOSITORY": "1st1/bend"})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.signature = base64.b64encode(bytes(64)).decode()

    def save_metadata(self):
        (self.root / "build.json").write_text(json.dumps(self.metadata))

    def test_feed_targets_exact_signed_archive_and_build(self):
        xml = ET.parse(feed.make_feed(self.root, self.signature))
        item = xml.find("./channel/item")
        self.assertEqual(item.findtext(feed.element("version")), "125001")
        self.assertEqual(item.findtext(feed.element("shortVersionString")), "0.3.0")
        self.assertEqual(item.findtext(feed.element("minimumSystemVersion")), "26.0")
        self.assertEqual(item.findtext(feed.element("hardwareRequirements")), "arm64")
        enclosure = item.find("enclosure")
        self.assertEqual(enclosure.get("length"), "15")
        self.assertEqual(enclosure.get("url"), "https://github.com/1st1/bend/releases/download/v0.3.0/Bend-0.3.0-arm64.dmg")
        self.assertEqual(enclosure.get(feed.element("edSignature")), self.signature)
        self.assertIn("&lt;something&gt;", item.findtext("description"))

    def test_reject_invalid_metadata_and_missing_archive(self):
        for field, value in [("RELEASE_VERSION", "../elsewhere"), ("BEND_BUILD_NUMBER", "0")]:
            old = self.metadata[field]
            self.metadata[field] = value
            self.save_metadata()
            with self.assertRaises(ValueError):
                feed.make_feed(self.root, self.signature)
            self.metadata[field] = old
        self.save_metadata()
        with self.assertRaises(ValueError):
            feed.make_feed(self.root, "bad")
        (self.root / "Bend-0.3.0-arm64.dmg").unlink()
        with self.assertRaises(ValueError):
            feed.make_feed(self.root, self.signature)

    @unittest.skipUnless(sys.platform == "darwin" and
                         (feed.ROOT / ".build/artifacts/sparkle/Sparkle/bin/sign_update").exists(),
                         "Requires the resolved Sparkle signing tools on macOS")
    def test_real_signatures_and_tamper_rejection(self):
        # Published RFC 8032 test vector; this is not an application signing credential.
        seed = base64.b64encode(bytes.fromhex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")).decode()
        public = base64.b64encode(bytes.fromhex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")).decode()
        project = self.root / "project"
        (project / "Assets").mkdir(parents=True)
        (project / "Assets/SparklePublicKey.txt").write_text(public)
        (project / "scripts").mkdir()
        shutil.copy(feed.ROOT / "scripts/update-key.swift", project / "scripts/update-key.swift")
        (project / ".build/artifacts/sparkle").mkdir(parents=True)
        (project / ".build/artifacts/sparkle/Sparkle").symlink_to(feed.ROOT / ".build/artifacts/sparkle/Sparkle", target_is_directory=True)
        with patch.object(feed, "ROOT", project), patch.dict(os.environ, {"BEND_UPDATE_PRIVATE_KEY": seed}):
            feed.sign_feed(self.root)
            signer = project / ".build/artifacts/sparkle/Sparkle/bin/sign_update"
            appcast = self.root / "appcast.xml"
            item = ET.parse(appcast).find("./channel/item")
            signature = item.find("enclosure").get(feed.element("edSignature"))
            archive = self.root / "Bend-0.3.0-arm64.dmg"
            archive.write_bytes(b"tampered archive")
            result = subprocess.run([str(signer), "--ed-key-file", "-", "--verify", str(archive), signature],
                                    input=seed, text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            appcast.write_text(appcast.read_text().replace("125001", "125002"))
            result = subprocess.run([str(signer), "--ed-key-file", "-", "--verify", str(appcast)],
                                    input=seed, text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            (project / "Assets/SparklePublicKey.txt").write_text(base64.b64encode(bytes(32)).decode())
            with self.assertRaises(subprocess.CalledProcessError):
                feed.sign_feed(self.root)

        verification_spec = importlib.util.spec_from_file_location("verify_key", feed.ROOT / "scripts/verify-update-key.py")
        verification = importlib.util.module_from_spec(verification_spec)
        verification_spec.loader.exec_module(verification)
        real_run = subprocess.run
        exports = []

        def export_fixture(command, **kwargs):
            if Path(command[0]).name == "generate_keys":
                target = Path(command[-1])
                self.assertEqual(target.parent.stat().st_mode & 0o777, 0o700)
                target.write_text(seed)
                self.assertEqual(target.stat().st_mode & 0o777, 0o600)
                exports.append(target)
                return subprocess.CompletedProcess(command, 0)
            return real_run(command, **kwargs)

        with patch.object(subprocess, "run", side_effect=export_fixture):
            output = io.StringIO()
            (project / "Assets/SparklePublicKey.txt").write_text(public)
            with redirect_stdout(output):
                verification.verify(project)
            self.assertIn("[1/4]", output.getvalue())
            self.assertIn("[4/4]", output.getvalue())
            self.assertIn("PASS:", output.getvalue())
            self.assertNotIn(seed, output.getvalue())
            self.assertEqual(len(exports), 1)
            self.assertFalse(exports[0].parent.exists())
            (project / "Assets/SparklePublicKey.txt").write_text(base64.b64encode(bytes(32)).decode())
            with redirect_stdout(io.StringIO()), self.assertRaises(subprocess.CalledProcessError):
                verification.verify(project)
            self.assertEqual(len(exports), 2)
            self.assertFalse(exports[1].parent.exists())


if __name__ == "__main__":
    unittest.main()
