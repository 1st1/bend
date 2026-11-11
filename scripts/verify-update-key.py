#!/usr/bin/env python3
"""Verify the existing update key with one Keychain export and visible progress."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def verify(root=ROOT):
    tools = root / ".build/artifacts/sparkle/Sparkle/bin"
    public = root / "Assets/SparklePublicKey.txt"
    if not public.is_file() or not (tools / "generate_keys").is_file():
        raise ValueError("Public key or Sparkle tools missing; configure the key and resolve packages first.")
    previous_mask = os.umask(0o077)
    try:
        with tempfile.TemporaryDirectory(prefix="bend-key-check-") as temporary:
            directory = Path(temporary)
            key = directory / "key"
            print("[1/4] Exporting the existing key. Approve the macOS Keychain prompt if shown...", flush=True)
            subprocess.run([str(tools / "generate_keys"), "--account", "bend-release-updates", "-x", str(key)],
                           check=True, stdout=subprocess.DEVNULL)
            print("[2/4] Checking that the private key matches Bend's public key...", flush=True)
            with key.open("rb") as secret:
                subprocess.run(["swift", str(root / "scripts/update-key.swift"), str(public)], stdin=secret, check=True)
            payload = directory / "test"
            payload.write_bytes(b"Bend signing verification fixture")
            signer = str(tools / "sign_update")
            print("[3/4] Signing a temporary test file...", flush=True)
            with key.open("rb") as secret:
                result = subprocess.run([signer, "--ed-key-file", "-", "-p", str(payload)],
                                        stdin=secret, stdout=subprocess.PIPE, text=True, check=True)
            print("[4/4] Verifying the signature...", flush=True)
            with key.open("rb") as secret:
                subprocess.run([signer, "--ed-key-file", "-", "--verify", str(payload), result.stdout.strip()],
                               stdin=secret, check=True)
    finally:
        os.umask(previous_mask)
    print("PASS: Key matches, signing and verification succeeded. Temporary key export removed.", flush=True)


if __name__ == "__main__":
    try:
        verify()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"FAIL: {error}. Temporary export cleaned up.", file=sys.stderr, flush=True)
        sys.exit(1)
    except KeyboardInterrupt:
        print("Cancelled. Temporary export cleaned up.", file=sys.stderr, flush=True)
        sys.exit(130)
