#!/usr/bin/env python3
"""Exercise real Changie in disposable git repositories."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


# @lat: [[tests#Release metadata and changelog]]
class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="bend-release-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        shutil.copy(ROOT / ".changie.yaml", self.root / ".changie.yaml")
        (self.root / "VERSION").write_text("0.1.0\n")
        (self.root / ".changes/unreleased").mkdir(parents=True)
        (self.root / ".changes/header.md").write_text("# Changelog\n")
        (self.root / ".changes/v0.1.0.md").write_text("## v0.1.0\n\nInitial baseline.\n")
        (self.root / ".changes/unreleased/minimum.yaml").write_text(
            "kind: Changed\nbody: Require macOS 26 or newer.\ntime: 2026-11-09T12:00:00Z\n")
        (self.root / "scripts").mkdir()
        for name in ("release.py", "changie.sh"):
            shutil.copy(ROOT / "scripts" / name, self.root / "scripts" / name)
        (self.root / ".build").mkdir()
        (self.root / ".build/tools").symlink_to(ROOT / ".build/tools", target_is_directory=True)
        (self.root / ".gitignore").write_text(".build/\n")
        self.command("bash", "scripts/changie.sh", "merge")
        self.command("git", "init", "-q")
        self.command("git", "config", "user.email", "test@example.invalid")
        self.command("git", "config", "user.name", "Release test")
        self.command("git", "add", ".")
        self.command("git", "commit", "-qm", "Baseline fixture")
        self.base = self.command("git", "rev-parse", "HEAD").stdout.strip()

    def command(self, *args, success=True):
        result = subprocess.run(args, cwd=self.root, text=True, capture_output=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def release(self, *args, success=True):
        return self.command("python3", "scripts/release.py", *args, success=success)

    def test_prepare(self):
        (self.root / "VERSION").write_text("0.2.0\n")
        self.release("prepare")
        self.assertTrue((self.root / ".changes/v0.2.0.md").is_file())
        self.assertEqual(list((self.root / ".changes/unreleased").glob("*.yaml")), [])
        self.assertIn("macOS 26", (self.root / "CHANGELOG.md").read_text())
        self.assertIn("\n\n## v0.1.0", (self.root / "CHANGELOG.md").read_text())
        self.command("git", "add", ".")
        self.command("git", "diff", "--cached", "--check")
        self.assertIn("version_changed=true", self.release("check", "--base-ref", self.base).stdout)
        self.release("prepare", success=False)

    def test_invalid_versions(self):
        for value in ("0.2.0", "0.0.9", "01.2.3", "1.2", "1.2.3-beta"):
            (self.root / "VERSION").write_text(value + "\n")
            self.release("check", success=False)

    def test_fragment_requirement(self):
        (self.root / "Sources").mkdir()
        (self.root / "Sources/Feature.swift").write_text("// feature\n")
        self.command("git", "add", ".")
        self.release("check", "--base-ref", self.base, success=False)
        self.release("check", "--base-ref", self.base, "--allow-no-fragment")
        (self.root / ".changes/unreleased/feature.yaml").write_text(
            "kind: Added\nbody: A new user-visible feature.\ntime: 2026-11-09T12:00:00Z\n")
        self.command("git", "add", ".")
        self.release("check", "--base-ref", self.base)

    def test_stale_changelog_and_history(self):
        with (self.root / "CHANGELOG.md").open("a") as stream:
            stream.write("Unexpected hand edit\n")
        self.release("check", success=False)
        with (self.root / ".changes/v0.1.0.md").open("a") as stream:
            stream.write("Rewritten history\n")
        self.command("bash", "scripts/changie.sh", "merge")
        self.command("git", "add", ".")
        self.release("check", "--base-ref", self.base, success=False)


if __name__ == "__main__":
    subprocess.run([str(ROOT / "scripts/changie.sh"), "--version"], cwd=ROOT, check=True)
    unittest.main()
