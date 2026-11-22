"""Install Bend's first-boot job into a stopped Apple Tart guest's Data volume."""
import os
from pathlib import Path
import plistlib
import re
import subprocess as sp
import sys
import tempfile


def plist(*args):
    return plistlib.loads(sp.check_output(args))


def seed(image, public_key):
    if os.getuid() != 0:
        sys.exit("Seeding the VM disk needs sudo.")
    os.environ["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    if not re.fullmatch(r"ssh-ed25519 [A-Za-z0-9+/=]+(?: [^\n]*)?", public_key):
        sys.exit("Expected an Ed25519 public key.")
    entities = plist("hdiutil", "attach", "-nomount", "-plist", image)["system-entities"]
    disk = next(e["dev-entry"] for e in entities if e.get("content-hint") == "GUID_partition_scheme")
    try:
        store = next(e["dev-entry"] for e in entities if e.get("content-hint") == "Apple_APFS")
        # Only use the Data volume backed by the exact store we just attached.
        data, = [v["DeviceIdentifier"] for c in plist("diskutil", "apfs", "list", "-plist")["Containers"]
                 if any("/dev/" + s["DeviceIdentifier"] == store for s in c["PhysicalStores"])
                 for v in c["Volumes"] if "Data" in v["Roles"]]
        root = Path(tempfile.mkdtemp()).resolve()
        try:
            sp.run(["diskutil", "mount", "nobrowse", "-mountOptions", "owners", "-mountPoint", root, data],
                   check=True, stdout=sys.stderr)
            try:
                if not os.path.ismount(root) or plist("diskutil", "info", "-plist", root)["DeviceIdentifier"] != data:
                    sys.exit("Guest Data volume did not mount at the requested path.")
                def guest(path):
                    target = root / path
                    if target.resolve() != target:
                        sys.exit(f"Refusing symlink in guest provisioning path: {path}")
                    return target

                # Do not reconfigure an existing developer account.
                state = guest("Library/BendTestVM")
                if not state.is_dir() and guest("private/var/db/.AppleSetupDone").exists():
                    sys.exit("Guest already configured. Use scripts/test-vm.sh enroll to keep its existing account.")
                state.mkdir(mode=0o755, exist_ok=True)
                guest("Library/BendTestVM/client.pub").write_text(public_key + "\n")
                script = Path(__file__).with_name("test-vm-firstboot.sh")
                guest("Library/BendTestVM/setup.sh").write_bytes(script.read_bytes())
                # Re-seeding a partial preparation must run the updated job, even
                # if an older job marked ready before the desktop actually logged in.
                guest("Library/BendTestVM/ready").unlink(missing_ok=True)
                hostkey = guest("private/etc/ssh/ssh_host_ed25519_key")
                pubpath = guest("private/etc/ssh/ssh_host_ed25519_key.pub")
                if not hostkey.exists():
                    sp.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", hostkey], check=True)
                job = {"Label": "org.bend.test-vm", "RunAtLoad": True,
                       "ProgramArguments": ["/bin/bash", "/Library/BendTestVM/setup.sh"]}
                dest = guest("Library/LaunchDaemons/org.bend.test-vm.plist")
                dest.parent.mkdir(exist_ok=True)
                dest.write_bytes(plistlib.dumps(job))
                dest.chmod(0o644)
                print(pubpath.read_text().strip(), flush=True)
            finally:
                # Never recursively clean a temporary directory containing a mounted disk.
                sp.run(["diskutil", "unmount", data], check=True, stdout=sys.stderr)
        finally:
            if not os.path.ismount(root):
                root.rmdir()
    finally:
        sp.run(["diskutil", "eject", disk], check=True, stdout=sys.stderr)


if __name__ == "__main__":
    seed(sys.argv[1], sys.argv[2])
