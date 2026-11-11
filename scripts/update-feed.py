#!/usr/bin/env python3
"""Create a signed Sparkle feed for the exact notarized release artifact."""
import base64
import html
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)


def element(name):
    return f"{{{SPARKLE}}}{name}"


# @lat: [[releases#Signed update feed]]
def make_feed(directory, signature):
    metadata = json.loads((directory / "build.json").read_text())
    version = metadata["RELEASE_VERSION"]
    build = metadata["BEND_BUILD_NUMBER"]
    repo = os.environ["GITHUB_REPOSITORY"]
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version):
        raise ValueError("Invalid update version")
    if not re.fullmatch(r"[1-9][0-9]*", build) or not re.fullmatch(r"[\w.-]+/[\w.-]+", repo):
        raise ValueError("Invalid update build or repository")
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError("Invalid archive signature")
    archive = directory / f"Bend-{version}-arm64.dmg"
    if not archive.is_file() or archive.is_symlink() or archive.stat().st_size == 0:
        raise ValueError("Missing update archive")
    rss = ET.Element("rss", version="2.0")
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "Bend Updates"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"Bend {version}"
    ET.SubElement(item, element("version")).text = build
    ET.SubElement(item, element("shortVersionString")).text = version
    ET.SubElement(item, element("minimumSystemVersion")).text = "26.0"
    ET.SubElement(item, element("hardwareRequirements")).text = "arm64"
    ET.SubElement(item, "description").text = "<pre>" + html.escape((directory / "RELEASE_NOTES.md").read_text()) + "</pre>"
    ET.SubElement(item, "enclosure", {
        "url": f"https://github.com/{repo}/releases/download/v{version}/{archive.name}",
        "length": str(archive.stat().st_size), "type": "application/octet-stream",
        element("edSignature"): signature,
    })
    feed = directory / "appcast.xml"
    ET.ElementTree(rss).write(feed, encoding="utf-8", xml_declaration=True)
    return feed


def sign_feed(directory):
    tools = ROOT / ".build/artifacts/sparkle/Sparkle/bin"
    public = ROOT / "Assets/SparklePublicKey.txt"
    secret = os.environ.get("BEND_UPDATE_PRIVATE_KEY")
    if secret:
        subprocess.run(["swift", str(ROOT / "scripts/update-key.swift"), str(public)],
                       input=secret, text=True, check=True)
        key_args = ["--ed-key-file", "-"]
    else:
        key_args = ["--account", "bend-release-updates"]
        key = subprocess.check_output([str(tools / "generate_keys"), *key_args, "-p"], text=True).strip()
        if key != public.read_text().strip():
            raise ValueError("Keychain update key does not match embedded public key")
    metadata = json.loads((directory / "build.json").read_text())
    version = metadata["RELEASE_VERSION"]
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version):
        raise ValueError("Invalid update version")
    archive = directory / f"Bend-{version}-arm64.dmg"
    signer = str(tools / "sign_update")
    result = subprocess.run([signer, *key_args, "-p", str(archive)], input=secret,
                            text=True, capture_output=True, check=True)
    signature = result.stdout.strip()
    feed = make_feed(directory, signature)
    subprocess.run([signer, *key_args, str(feed)], input=secret, text=True, check=True)
    subprocess.run([signer, *key_args, "--verify", str(feed)], input=secret, text=True, check=True)
    subprocess.run([signer, *key_args, "--verify", str(archive), signature], input=secret, text=True, check=True)


if __name__ == "__main__":
    try:
        if len(sys.argv) != 2:
            raise ValueError("Usage: update-feed.py ASSET_DIRECTORY")
        sign_feed(Path(sys.argv[1]))
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        print(f"Update feed failed: {error}", file=sys.stderr)
        sys.exit(1)
