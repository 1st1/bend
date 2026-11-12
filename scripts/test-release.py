#!/usr/bin/env python3
"""Exercise real Changie in disposable git repositories."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


# @lat: [[lat.md/tests/build-tests#Release metadata and changelog]]
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
        self.command("git", "tag", "v0.1.0")
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
        self.assertIn("release_required=true", self.release("check", "--base-ref", self.base).stdout)
        # A fresh checkout omits the now-empty, untracked fragment directory.
        (self.root / ".changes/unreleased").rmdir()
        self.assertIn("version_changed=true", self.release("check", "--base-ref", self.base).stdout)
        self.assertFalse((self.root / ".changes/unreleased").exists())
        self.release("prepare", success=False)

    def test_malformed_fragment(self):
        (self.root / ".changes/unreleased/broken.yaml").write_text("kind: [invalid\n")
        self.release("check", success=False)

    def test_merged_version_bump_and_later_push(self):
        self.command("git", "checkout", "-qb", "release-fixture")
        (self.root / "VERSION").write_text("0.2.0\n")
        self.release("prepare")
        self.command("git", "add", ".")
        self.command("git", "commit", "-qm", "Prepare release")
        self.command("git", "checkout", "--detach", self.base)
        self.command("git", "merge", "--no-ff", "release-fixture", "-m", "Merge release")
        self.assertIn("version_changed=true", self.release("check", "--base-ref", self.base,
                                                         "--allow-no-fragment").stdout)
        merged = self.command("git", "rev-parse", "HEAD").stdout.strip()
        self.command("git", "commit", "--allow-empty", "-qm", "Later main push")
        self.assertIn("version_changed=false", self.release("check", "--base-ref", merged,
                                                          "--allow-no-fragment").stdout)
        self.assertIn("release_required=false", self.release("check", "--base-ref", merged,
                                                           "--allow-no-fragment").stdout)

    def test_revise_untagged_candidate(self):
        (self.root / "VERSION").write_text("0.2.0\n")
        self.release("prepare")
        self.command("git", "add", ".")
        self.command("git", "commit", "-qm", "Unpublished candidate")
        candidate = self.command("git", "rev-parse", "HEAD").stdout.strip()
        with (self.root / ".changes/v0.2.0.md").open("a") as stream:
            stream.write("- Include the new background-tab behavior.\n")
        (self.root / "Sources").mkdir()
        (self.root / "Sources/Feature.swift").write_text("// feature\n")
        self.command("bash", "scripts/changie.sh", "merge")
        self.command("git", "add", ".")
        result = self.release("check", "--base-ref", candidate)
        self.assertIn("version_changed=false", result.stdout)
        self.assertIn("release_required=true", result.stdout)

        pending = self.root / ".changes/unreleased/extra.yaml"
        pending.write_text("kind: Added\nbody: Unbatched feature.\ntime: 2026-11-09T12:00:00Z\n")
        result = self.release("check", "--base-ref", candidate, success=False)
        self.assertIn("must batch all pending", result.stderr)
        pending.unlink()

        # Even an untagged older release cannot be rewritten.
        self.command("git", "tag", "-d", "v0.1.0")
        older = self.root / ".changes/v0.1.0.md"
        original = older.read_text()
        older.write_text(original + "Rewritten history\n")
        self.command("bash", "scripts/changie.sh", "merge")
        result = self.release("check", "--base-ref", candidate, success=False)
        self.assertIn("Do not rewrite released", result.stderr)
        older.write_text(original)
        self.command("bash", "scripts/changie.sh", "merge")

        # Once a tag exists, the candidate is immutable too.
        self.command("git", "tag", "v0.2.0")
        result = self.release("check", "--base-ref", candidate, success=False)
        self.assertIn("Do not rewrite released", result.stderr)

    def test_invalid_versions(self):
        for value in ("0.2.0", "0.0.9", "01.2.3", "1.2", "1.2.3-beta"):
            (self.root / "VERSION").write_text(value + "\n")
            self.release("check", success=False)

    def test_initial_version_is_not_a_release(self):
        self.command("git", "rm", "VERSION")
        self.command("git", "commit", "-qm", "Fixture before version tracking")
        base = self.command("git", "rev-parse", "HEAD").stdout.strip()
        (self.root / "VERSION").write_text("0.1.0\n")
        self.command("git", "add", "VERSION")
        self.assertIn("version_changed=false", self.release("check", "--base-ref", base).stdout)

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
