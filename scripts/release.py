#!/usr/bin/env python3
"""Validate release metadata, or batch fragments for the checked-in VERSION."""
import argparse
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
VERSION_PATTERN = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")


def version_tuple(value):
    if not VERSION_PATTERN.fullmatch(value):
        raise ValueError("VERSION must be a numeric MAJOR.MINOR.PATCH version")
    return tuple(map(int, value.split(".")))


def run(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def changie(*args):
    return run(str(ROOT / "scripts/changie.sh"), *args)


def release_versions():
    return {version_tuple(p.stem[1:]): p for p in (ROOT / ".changes").glob("v*.md")}


def check(base_ref=None, allow_no_fragment=False):
    current = (ROOT / "VERSION").read_text().strip()
    version = version_tuple(current)
    versions = release_versions()
    if not versions or max(versions) != version:
        raise ValueError("VERSION must match the latest release notes; run scripts/release.py prepare")
    if not versions[version].read_text().startswith(f"## v{current}\n"):
        raise ValueError("Release note heading does not match VERSION")
    if changie("merge", "--dry-run") != (ROOT / "CHANGELOG.md").read_text().strip():
        raise ValueError("CHANGELOG.md is stale; run scripts/changie.sh merge")
    # Exercise Changie's own fragment parser without mutating any files.
    changie("batch", "patch", "--dry-run")
    changed = False
    if base_ref:
        run("git", "rev-parse", "--verify", f"{base_ref}^{{commit}}")
        files = run("git", "ls-tree", "--name-only", base_ref, "VERSION").splitlines()
        previous = run("git", "show", f"{base_ref}:VERSION") if files else None
        changed = previous != current
        if previous and version < version_tuple(previous):
            raise ValueError("VERSION cannot decrease")
        if changed and previous:
            if list((ROOT / ".changes/unreleased").glob("*.yaml")):
                raise ValueError("Release PRs must batch all pending changelog fragments")
            if run("git", "ls-tree", "--name-only", base_ref, f".changes/v{current}.md"):
                raise ValueError("A published version cannot be reused")
        # Released history is immutable; the newly added release may be edited.
        historical = run("git", "ls-tree", "--name-only", base_ref, ".changes/").splitlines()
        for path in historical:
            if re.fullmatch(r"\.changes/v[0-9]+\.[0-9]+\.[0-9]+\.md", path):
                if run("git", "diff", base_ref, "--", path):
                    raise ValueError(f"Do not rewrite released changelog history: {path}")
        paths = run("git", "diff", "--name-only", base_ref).splitlines()
        user_facing = any(p.startswith(("Sources/", "Assets/")) or p == "Package.swift" for p in paths)
        new_fragments = run("git", "diff", "--name-only", "--diff-filter=A", base_ref,
                            "--", ".changes/unreleased/*.yaml").splitlines()
        if user_facing and not changed and not new_fragments and not allow_no_fragment:
            raise ValueError("Add a Changie fragment, or apply the no-changelog PR label for internal-only work")
    output = f"version={current}\nversion_changed={'true' if changed else 'false'}\n"
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
            stream.write(output)
    print(output, end="")


def prepare():
    current = (ROOT / "VERSION").read_text().strip()
    version = version_tuple(current)
    versions = release_versions()
    if versions and version <= max(versions):
        raise ValueError("First increase VERSION to a new MAJOR.MINOR.PATCH version")
    # Validate before Changie consumes fragments.
    changie("batch", f"v{current}", "--allow-no-changes=false", "--dry-run")
    changie("batch", f"v{current}", "--allow-no-changes=false")
    changie("merge")
    check()
    print(f"Prepared v{current}. Commit VERSION, CHANGELOG.md, and .changes in your release PR.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("check", "prepare"))
    parser.add_argument("--base-ref", help="PR base commit used to detect a release and enforce fragments")
    parser.add_argument("--allow-no-fragment", action="store_true")
    args = parser.parse_args()
    try:
        if args.command == "prepare":
            prepare()
        else:
            check(args.base_ref, args.allow_no_fragment)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"Release metadata error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
