#!/usr/bin/env python3
"""Publish the notarized build from a successful version-bump push to main."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import base64
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent


def api(path, method="GET", data=None, missing_ok=False):
    command = ["gh", "api", path, "--method", method]
    if data is not None:
        command += ["--input", "-"]
    result = subprocess.run(command, input=json.dumps(data) if data is not None else None,
                            text=True, capture_output=True)
    if result.returncode:
        if missing_ok and "(HTTP 404)" in result.stderr:
            return None
        raise RuntimeError(result.stderr.strip() or "GitHub API request failed")
    return json.loads(result.stdout)


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def validated_assets(directory):
    if (os.environ.get("GITHUB_ACTIONS"), os.environ.get("GITHUB_EVENT_NAME"),
        os.environ.get("GITHUB_REF")) != ("true", "push", "refs/heads/main"):
        raise ValueError("Release publication requires a push to main in GitHub Actions")
    version = os.environ["RELEASE_VERSION"]
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version):
        raise ValueError("Invalid release version")
    sha = os.environ["GITHUB_SHA"]
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ValueError("Invalid release commit")
    if (ROOT / "VERSION").read_text().strip() != version:
        raise ValueError("Release version does not match the checkout")
    paths = [directory / f"Bend-{version}-arm64.dmg", directory / "SHA256SUMS",
             directory / "RELEASE_NOTES.md", directory / "build.json", directory / "appcast.xml"]
    if any(not path.is_file() or path.is_symlink() or path.stat().st_size == 0 for path in paths):
        raise ValueError("Release assets are missing or invalid")
    metadata = json.loads(paths[3].read_text())
    if any(metadata.get(key) != os.environ[key] for key in ("RELEASE_VERSION", "GITHUB_SHA", "GITHUB_RUN_ID")):
        raise ValueError("Build provenance does not match this release run")
    if paths[1].read_text().strip() != f"{digest(paths[0])}  {paths[0].name}":
        raise ValueError("DMG checksum does not match")
    if paths[2].read_bytes() != (ROOT / f".changes/v{version}.md").read_bytes():
        raise ValueError("Release notes do not match the checkout")
    namespace = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
    feed = ET.fromstring(paths[4].read_bytes())
    items = feed.findall("./channel/item")
    if len(items) != 1:
        raise ValueError("Update feed must contain this release only")
    item = items[0]
    archive = item.find("enclosure")
    expected_url = f"https://github.com/{os.environ['GITHUB_REPOSITORY']}/releases/download/v{version}/{paths[0].name}"
    if (item.findtext(namespace + "version") != metadata.get("BEND_BUILD_NUMBER") or
        item.findtext(namespace + "shortVersionString") != version or
        item.findtext(namespace + "minimumSystemVersion") != "26.0" or
        item.findtext(namespace + "hardwareRequirements") != "arm64" or archive is None or
        archive.get("url") != expected_url or archive.get("length") != str(paths[0].stat().st_size) or
        len(base64.b64decode(archive.get(namespace + "edSignature", ""), validate=True)) != 64):
        raise ValueError("Update feed does not match the published artifact")
    return version, sha, paths


def verify_assets(release, paths, check_digests):
    assets = {asset["name"]: asset for asset in release["assets"]}
    for path in paths:
        asset = assets.get(path.name)
        if not asset or asset.get("state") != "uploaded":
            raise ValueError(f"Release asset is missing or incomplete: {path.name}")
        if check_digests and (asset.get("size") != path.stat().st_size or
                              asset.get("digest") != f"sha256:{digest(path)}"):
            raise ValueError(f"Uploaded release asset failed verification: {path.name}")


def publish(directory):
    version, sha, paths = validated_assets(directory)
    repo = os.environ["GITHUB_REPOSITORY"]
    prefix = f"repos/{repo}"
    tag = f"v{version}"
    reference = api(f"{prefix}/git/ref/tags/{tag}", missing_ok=True)
    if reference:
        target = reference["object"]
        while target["type"] == "tag":
            target = api(f"{prefix}/git/tags/{target['sha']}")["object"]
        if target["type"] != "commit" or target["sha"] != sha:
            raise ValueError(f"Tag {tag} already points to a different commit; refusing to move it")
    else:
        api(f"{prefix}/git/refs", "POST", {"ref": f"refs/tags/{tag}", "sha": sha})

    release = api(f"{prefix}/releases/tags/{tag}", missing_ok=True)
    if release and not release["draft"]:
        # Reruns may have a newer build number. Never replace published binaries.
        verify_assets(release, paths, check_digests=False)
        print(f"Release already published: {release['html_url']}")
        return release["html_url"]
    fields = {"tag_name": tag, "target_commitish": sha, "name": f"Bend {version}",
              "body": paths[2].read_text(), "draft": True, "prerelease": False}
    if release:
        release = api(f"{prefix}/releases/{release['id']}", "PATCH", fields)
    else:
        release = api(f"{prefix}/releases", "POST", fields)
    subprocess.run(["gh", "release", "upload", tag, *map(str, paths), "--repo", repo, "--clobber"], check=True)
    release = api(f"{prefix}/releases/{release['id']}")
    verify_assets(release, paths, check_digests=True)
    release = api(f"{prefix}/releases/{release['id']}", "PATCH", {"draft": False, "make_latest": "legacy"})
    print(f"Published: {release['html_url']}")
    return release["html_url"]


def main():
    try:
        if len(sys.argv) != 2:
            raise ValueError("Usage: publish-release.py ASSET_DIRECTORY")
        url = publish(Path(sys.argv[1]))
        if os.environ.get("GITHUB_STEP_SUMMARY"):
            with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as stream:
                stream.write(f"[Download the published release]({url})\n")
    except (ValueError, KeyError, OSError, RuntimeError, subprocess.CalledProcessError, ET.ParseError) as error:
        print(f"Release publication failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
