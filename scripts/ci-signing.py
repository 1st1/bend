#!/usr/bin/env python3
"""Set up and remove the ephemeral GitHub Actions signing keychain."""
import base64
import json
import os
from pathlib import Path
import secrets
import shlex
import shutil
import subprocess
import sys
import tempfile

REQUIRED = ("BEND_CERTIFICATE_P12_BASE64", "BEND_CERTIFICATE_PASSWORD",
            "BEND_NOTARY_KEY_P8", "BEND_NOTARY_KEY_ID", "BEND_NOTARY_ISSUER_ID")


def run(*args):
    return subprocess.run(args, check=True, text=True, capture_output=True).stdout.strip()


def state_path():
    if os.environ.get("GITHUB_ACTIONS") != "true":
        raise ValueError("This helper is only for an ephemeral GitHub Actions runner")
    return Path(os.environ["RUNNER_TEMP"]) / "bend-signing-state.json"


def private_write(path, data):
    with open(path, "xb") as stream:
        os.chmod(path, 0o600)
        stream.write(data)


def setup():
    missing = [name for name in REQUIRED if not os.environ.get(name)]
    if missing:
        raise ValueError("Missing release-signing environment secrets: " + ", ".join(missing))
    state = state_path()
    if state.exists():
        raise ValueError("Signing state already exists; clean it up before setup")
    original = shlex.split(run("security", "list-keychains", "-d", "user"))
    directory = Path(tempfile.mkdtemp(prefix="bend-signing-", dir=state.parent))
    keychain = directory / "signing.keychain-db"
    private_write(state, json.dumps({"directory": str(directory), "original": original}).encode())
    certificate = directory / "certificate.p12"
    key = directory / "notary.p8"
    encoded_certificate = "".join(os.environ[REQUIRED[0]].split())
    private_write(certificate, base64.b64decode(encoded_certificate, validate=True))
    private_write(key, os.environ["BEND_NOTARY_KEY_P8"].encode())
    password = secrets.token_urlsafe(32)
    run("security", "create-keychain", "-p", password, str(keychain))
    run("security", "set-keychain-settings", "-lut", "7200", str(keychain))
    run("security", "unlock-keychain", "-p", password, str(keychain))
    run("security", "import", str(certificate), "-P", os.environ["BEND_CERTIFICATE_PASSWORD"],
        "-t", "cert", "-f", "pkcs12", "-k", str(keychain), "-T", "/usr/bin/codesign", "-T", "/usr/bin/security")
    run("security", "set-key-partition-list", "-S", "apple-tool:,apple:", "-s", "-k", password, str(keychain))
    run("security", "list-keychains", "-d", "user", "-s", str(keychain), *original)
    run("xcrun", "notarytool", "store-credentials", "bend-notary", "--key", str(key),
        "--key-id", os.environ["BEND_NOTARY_KEY_ID"], "--issuer", os.environ["BEND_NOTARY_ISSUER_ID"],
        "--keychain", str(keychain))
    # The imported identity and notarization profile are sufficient from here.
    certificate.unlink()
    key.unlink()
    with open(os.environ["GITHUB_ENV"], "a") as stream:
        stream.write(f"BEND_NOTARY_KEYCHAIN={keychain}\nBEND_NOTARY_PROFILE=bend-notary\n")
    print("Temporary signing keychain configured")


def cleanup():
    state = state_path()
    if not state.exists():
        return
    data = json.loads(state.read_text())
    directory = Path(data["directory"])
    if directory.parent != state.parent or not directory.name.startswith("bend-signing-"):
        raise ValueError("Unexpected signing directory")
    failures = []
    for args in (("security", "list-keychains", "-d", "user", "-s", *data["original"]),
                 ("security", "delete-keychain", str(directory / "signing.keychain-db"))):
        try:
            run(*args)
        except subprocess.CalledProcessError:
            failures.append(args[1])
    # Remove raw credentials even when keychain cleanup encounters an error.
    shutil.rmtree(directory)
    state.unlink()
    if failures:
        raise ValueError("Signing cleanup failed: " + ", ".join(failures))
    print("Temporary signing credentials removed")


def main():
    try:
        if sys.argv[1:] == ["setup"]:
            setup()
        elif sys.argv[1:] == ["cleanup"]:
            cleanup()
        else:
            raise ValueError("Usage: ci-signing.py setup|cleanup")
    except subprocess.CalledProcessError as error:
        # Never include full arguments: security receives passwords as arguments.
        print(f"Signing command failed: {error.cmd[0]} (exit {error.returncode})", file=sys.stderr)
        return 1
    except (ValueError, KeyError, OSError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
