"""Run Bend's test runner on a persistent, windowless local Tart guest."""
import fcntl
import hashlib
from collections import deque
try:
    import curses
except ImportError:
    curses = None
import json
import os
from pathlib import Path
import platform
import queue
import re
import shlex
import shutil
import subprocess as sp
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
LEGACY = "bend-tests-apple-tahoe"
VM = LEGACY + "-preparing"
BASE = LEGACY + "-baseline"
WORKERS = (LEGACY + "-run-1", LEGACY + "-run-2")
GUESTS = (VM, BASE, *WORKERS, LEGACY, LEGACY + "-2")
IPSW = ("https://updates.cdn-apple.com/2026SummerFCS/fullrestores/140-75212/"
        "A2A24B94-1FC1-45A3-93F7-C51B02AF1F4D/UniversalMac_26.6.2_25G83_Restore.ipsw")
IPSW_CACHE_NAME = "sha256:885503b7f4b06609e9a512f2befd40f59730640a3f1233e3892d60affdd51c95.ipsw"
KEY = Path.home() / ".ssh/bend-test-vm"
STATE = Path.home() / "Library/Caches/Bend/test-vm"
CLT_CACHE = "clt-26.6-140-17812"
GUEST_DIR = "/Users/admin/bend-test-worktree"
HELP = ("Usage: scripts/test-vm.sh [--jobs 2 | --filter … or other scripts/test.sh arguments]\n"
        "Guests are prepared automatically. Optional commands: prefetch, setup [--jobs 2], stop, wipe, enroll (legacy guest).")


def status(message):
    print(f"[test-vm] {message}", file=sys.stderr, flush=True)


def digest(path):
    sha = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            sha.update(block)
    return sha.hexdigest()


def cache_download(path, url, expected, existing=None):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_file() and digest(path) == expected:
        return
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as tmp:
        partial = Path(tmp.name)
    try:
        if existing and existing.is_file() and digest(existing) == expected:
            shutil.copyfile(existing, partial)
        else:
            status(f"Downloading {url}…")
            sp.run(["curl", "--fail", "--location", "--proto", "=https", "--retry", "2", "--output", partial,
                    url], check=True)
        if digest(partial) != expected:
            sys.exit(f"Checksum mismatch for {url}; download not cached.")
        partial.replace(path)
    finally:
        partial.unlink(missing_ok=True)


def sparkle_archive(project):
    # Pin the binaryTarget checksum from Sparkle's manifest at the locked revision.
    pins = json.loads((Path(project) / "Package.resolved").read_text())["pins"]
    if not any(p["identity"] == "sparkle" and p["state"].get("revision") ==
               "ab7d71291238df6e0492143b120c9b696a35f603" for p in pins):
        return None  # Another revision: let SwiftPM resolve its own binary target.
    url = "https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-for-Swift-Package-Manager.zip"
    name = re.sub(r"[^A-Za-z0-9]", "_", url)  # SwiftPM's URL-based artifact cache filename.
    path = STATE / "swiftpm-artifacts" / name
    cache_download(path, url, "4c2e48a3e50ebcc2c88a58a4c7264a1a99c3c31857ce754357afb9cdb323022a",
                   Path.home() / "Library/Caches/org.swift.swiftpm/artifacts" / name)
    return path


def tool(name, prefixes):
    if shutil.which(name):
        return name
    return next((str(Path(p) / name) for p in prefixes if os.access(Path(p) / name, os.X_OK)), None)


def install_help(brew, port):
    commands = []
    if brew:
        commands.append(f"{brew} install openai/tools/tart")
    if port:
        commands.append(f"sudo {port} install tart")
    if commands:
        return "Install Tart, then retry:\n  " + "\n  or: ".join(commands)
    return "Install Tart from https://tart.run/ (or install Homebrew or MacPorts first), then retry."


def snapshot(stage):
    # Mirror exactly the git-visible working files, including uncommitted edits and deletions.
    files = sp.check_output(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd=ROOT)
    for raw in filter(None, files.split(b"\0")):
        rel = os.fsdecode(raw)
        src, dst = ROOT / rel, Path(stage) / rel
        if not src.is_symlink() and not src.is_file():
            continue
        dst.parent.mkdir(parents=True, exist_ok=True)
        if src.is_symlink():
            dst.symlink_to(os.readlink(src))
        else:
            shutil.copy2(src, dst)


def ssh():
    # The two local clones share a host key enrolled during provisioning.
    known = STATE / "known_hosts"
    return ["ssh", "-F", "/dev/null", *(["-o", f'UserKnownHostsFile="{known}"'] if known.exists() else []),
            "-i", str(KEY), "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=yes", "-o", f"HostKeyAlias={VM}", "-o", "ConnectTimeout=4",
            "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3"]


def remote(ip, *args):
    return [*ssh(), f"admin@{ip}", shlex.join(args)]


def enrollment_hint(pair=False):
    return (f"Start the primary guest with `tart run {VM}`. In the guest, configure the admin desktop, "
            "Xcode and Remote Login (README.md). While it is running, use a second host terminal: "
            "`scripts/test-vm.sh enroll`." + ("\nThen shut down the primary from its Apple menu and rerun "
            "`scripts/test-vm.sh setup --jobs 2` to create the second VM." if pair else ""))


def enroll(tart):
    info = sp.run([tart, "get", VM, "--format", "json"], capture_output=True)
    if info.returncode or not json.loads(info.stdout)["Running"]:
        sys.exit(enrollment_hint())
    addr = sp.run([tart, "ip", VM], text=True, capture_output=True)
    if addr.returncode or not addr.stdout.strip():
        sys.exit(enrollment_hint())
    ip = addr.stdout.strip()
    KEY.parent.mkdir(mode=0o700, exist_ok=True)
    if not KEY.exists():
        sp.run(["ssh-keygen", "-t", "ed25519", "-N", "", "-f", str(KEY)], check=True)
    status("Compare the SSH fingerprint with `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` in the guest.")
    sp.run(["ssh-copy-id", "-F", "/dev/null", "-i", str(KEY) + ".pub", "-o", f"HostKeyAlias={VM}",
            "-o", "HostKeyAlgorithms=ssh-ed25519", f"admin@{ip}"], check=True)
    sp.run(remote(ip, "/usr/bin/true"), check=True)
    status("Passwordless SSH verified. Shut down the primary guest before cloning it.")


def vm_info(tart, vm):
    info = sp.run([tart, "get", vm, "--format", "json"], capture_output=True)
    return None if info.returncode else json.loads(info.stdout)


def provision(tart, info):
    """Enroll the host key offline; leave first-boot work to the guest."""
    stamp = STATE / "seeded"
    seed_version = f"clt-softwareupdate-v1:{info['MACAddress']}"
    if stamp.exists() and stamp.read_text() == seed_version and KEY.exists() and (STATE / "known_hosts").exists():
        return True
    if not stamp.exists() and KEY.exists() and not sp.run(["ssh-keygen", "-F", VM],
            stdout=sp.DEVNULL, stderr=sp.DEVNULL).returncode:
        return False  # Existing manually enrolled guest.
    KEY.parent.mkdir(mode=0o700, exist_ok=True)
    if not KEY.exists():
        sp.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", KEY], check=True)
    pub = sp.check_output(["ssh-keygen", "-y", "-f", KEY], text=True).strip()
    disk = Path(os.environ.get("TART_HOME", Path.home() / ".tart")) / "vms" / VM / "disk.img"
    command = ["sudo", "/usr/bin/python3", str(ROOT / "scripts/test-vm-seed.py"), str(disk), pub]
    status("First-time setup needs host sudo to mount the guest disk and install its first-boot job and SSH key.")
    if info["Running"]:
        status(f"The runner will stop {VM} before mounting its disk.")
    print(f"\n  {shlex.join(command)}\n", file=sys.stderr, flush=True)
    if not sys.stdin.isatty():
        sys.exit("Confirmation requires an interactive terminal. No sudo command was run.")
    print("Run this sudo command? [y/N] ", file=sys.stderr, end="", flush=True)
    if sys.stdin.readline().strip().lower() not in ("y", "yes"):
        sys.exit("Provisioning cancelled. No sudo command was run.")
    if info["Running"]:
        sp.run([tart, "stop", VM], check=True)
    hostkey = sp.check_output(command, text=True).strip()
    if not hostkey.startswith("ssh-ed25519 "):
        sys.exit("Did not receive the guest SSH host key.")
    (STATE / "known_hosts").write_text(f"{VM} {hostkey}\n")
    stamp.write_text(seed_version)
    return True


def boot(tart, vm, boots, managed):
    log = STATE / ("tart-2.log" if vm == WORKERS[1] else "tart.log")
    boots[vm] = None
    if not vm_info(tart, vm)["Running"]:
        status(f"Starting {vm} in the background. Boot log: {log}")
        with log.open("w") as out:
            boots[vm] = sp.Popen([tart, "run", "--no-graphics", "--no-clipboard", vm],
                                 stdin=sp.DEVNULL, stdout=out, stderr=out, start_new_session=True)
    return wait_ready(tart, vm, boots[vm], log, managed)


def sync(ip, stage, artifact):
    if artifact:
        cache = "/Users/admin/Library/Caches/org.swift.swiftpm/artifacts"
        sp.run(remote(ip, "/bin/mkdir", "-p", cache), check=True)
        sp.run(["rsync", "-t", "-e", shlex.join(ssh()), "--rsync-path=/usr/bin/rsync",
                str(artifact), f"admin@{ip}:{cache}/"], check=True)
    sp.run(["rsync", "-rltpc", "--delete", "--exclude=/.build/", "--exclude=/.swiftpm/",
            "-e", shlex.join(ssh()), "--rsync-path=/usr/bin/rsync",
            stage + "/", f"admin@{ip}:{GUEST_DIR}/"], check=True)


def build_archive(baseline, stage):
    # Same toolchain, SDK, build flags, dependency graph and absolute guest paths.
    # Source edits within that environment are handled by SwiftPM's incremental build.
    key = hashlib.sha256(b"vm-build-v1\0" + baseline["MACAddress"].encode())
    for name in ("Package.swift", "Package.resolved", "scripts/test.sh"):
        key.update(bytes.fromhex(digest(Path(stage) / name)))
    inputs = hashlib.sha256()
    for path in sorted(Path(stage).rglob("*")):
        if path.is_symlink():
            content = b"link:" + os.fsencode(os.readlink(path))
        elif path.is_file():
            content = bytes.fromhex(digest(path))
        else:
            continue
        inputs.update(os.fsencode(path.relative_to(stage)) + b"\0" + str(path.lstat().st_mode).encode()
                      + b"\0" + content + b"\0")
    return STATE / "swift-build" / f"{key.hexdigest()}-{inputs.hexdigest()}.tar.gz"


def restore_build(ip, archive):
    status(f"Restoring private .build ({archive.stat().st_size / 1e6:.0f} MB) in guest {ip}…")
    with archive.open("rb") as stream:
        sp.run(remote(ip, "/usr/bin/tar", "-xzpf", "-", "-C", GUEST_DIR),
               stdin=stream, check=True, timeout=600)


def save_build(ip, archive):
    status("Saving completed .build to the host…")
    archive.parent.mkdir(exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=archive.parent, delete=False) as tmp:
        partial = Path(tmp.name)
        try:
            sp.run(remote(ip, "/usr/bin/env", "COPYFILE_DISABLE=1", "/usr/bin/tar", "--format", "pax",
                          "--options", "gzip:compression-level=1", "-czf", "-", "-C", GUEST_DIR, ".build"),
                   stdout=tmp, check=True, timeout=600)
            partial.replace(archive)
        finally:
            partial.unlink(missing_ok=True)
    status(f"Saved .build ({archive.stat().st_size / 1e6:.0f} MB).")
    for old in archive.parent.glob("*.tar.gz"):
        if old != archive:
            old.unlink()


def prepare_build(addresses, archive):
    primary, *others = addresses.values()
    if archive.exists():
        status("Working tree matches the saved build; skipping compilation.")
        for ip in addresses.values():
            restore_build(ip, archive)
        return
    compatible = next(archive.parent.glob(archive.name.split("-")[0] + "-*.tar.gz"), None)
    if compatible:
        restore_build(primary, compatible)
    # `list` builds and loads the test bundle, but does not execute any tests.
    run_shards({WORKERS[0]: primary}, ["list"], build=True)
    save_build(primary, archive)
    for ip in others:
        restore_build(ip, archive)


QUIET_PROBE = 60
IDLE_LIMIT = 300   # Leave headroom for the guest's 180-second isolated-group timeout.
WALL_LIMIT = 3600


def run_shards(addresses, args=(), *, build=False, prebuilt=False):
    vms = list(addresses)
    events = queue.Queue()
    parallel = len(vms) > 1
    interactive = parallel and curses and sys.stdout.isatty() and sys.stdin.isatty() and os.environ.get("TERM", "dumb") != "dumb"
    start = time.monotonic()
    panes = [dict(vm=vm, lines=deque(maxlen=200), phase="Building / discovering tests",
                  current=0, done=0, total=0, code=None, eof=False, pid=None,
                  last=start, next_probe=start + QUIET_PROBE) for vm in vms]

    def output(worker, i):
        try:
            with worker.stdout as stream:
                for line in stream:
                    events.put((i, line))
        finally:
            events.put((i, None))

    def monitor(screen=None):
        last_draw = 0
        while any(p["code"] is None for p in panes):
            try:
                i, line = events.get(timeout=0.15)
            except queue.Empty:
                pass
            else:
                p = panes[i]
                if p["code"] is not None:
                    continue
                if line is None:
                    p["eof"] = True
                else:
                    p["last"] = time.monotonic()
                    p["next_probe"] = p["last"] + QUIET_PROBE
                    if not p["pid"] and (pid := re.fullmatch(r"BEND_VM_TEST_PID=(\d+)\n", line)):
                        p["pid"] = pid[1]
                        continue
                    logs[i].write(line)
                    if screen is None:
                        print((f"[shard {i + 1}/{len(vms)}] " if parallel else "") + line, end="", flush=True)
                    text = line.rstrip()
                    if text:
                        p["lines"].append(text)
                    if ": error: " in text or " recorded an issue " in text:
                        p.setdefault("diagnostic", text)
                    if match := re.match(r"^Discovered .* in (\d+) isolated groups\.$", text):
                        p["total"] = int(match[1])
                    elif p["total"] and (match := re.match(r"^\[(\d+)/(\d+)\] (.+)", text)):
                        if int(match[2]) == p["total"] and int(match[1]) == p["current"] + 1:
                            p.update(done=p["current"], current=int(match[1]), phase=match[3])
                    elif text == "Failed groups:":
                        # The runner reports accumulated failures after finishing its loop.
                        p["done"] = p["current"]
            now = time.monotonic()
            for i, p in enumerate(panes):
                if p["code"] is not None:
                    continue
                worker = workers[i][0]
                if p["eof"] and (code := worker.poll()) is not None:
                    p["code"] = code
                    p["phase"] = "Passed" if not code else f"FAILED (exit {code})"
                    if not code:
                        p["done"] = p["total"]
                    continue
                idle = now - p["last"]
                reason = None
                if now - start >= WALL_LIMIT:
                    reason = f"exceeded {WALL_LIMIT}s wall time"
                elif idle >= IDLE_LIMIT:
                    reason = f"no output for {int(idle)}s"
                elif now >= p["next_probe"]:
                    p["next_probe"] = now + QUIET_PROBE
                    note = f"Quiet for {int(idle)}s ({p['phase']})"
                    if p["pid"]:
                        # A responsive sshd alone does not mean the test command still exists.
                        try:
                            probe = sp.run(remote(addresses[p["vm"]], "/bin/sh", "-c",
                                                  'kill -0 "$1" 2>/dev/null || exit 44', "probe", p["pid"]),
                                           capture_output=True, timeout=6)
                            if probe.returncode == 44 and worker.poll() is None:
                                reason = "guest test process disappeared while SSH remained open"
                            elif not probe.returncode:
                                note += "; guest test process still present"
                            else:
                                note += "; guest probe unavailable"
                        except sp.TimeoutExpired:
                            note += "; guest probe timed out"
                    logs[i].write(f"[watchdog] {note}\n")
                    p["lines"].append(note)
                    if screen is None:
                        status(f"{p['vm']}: {note}")
                if reason:
                    message = f"{reason} during {p['phase']}"
                    logs[i].write(f"[watchdog] {message}\n")
                    p["lines"].append(message)
                    p.update(code=124, phase="Timed out", diagnostic=message)
                    if screen is None:
                        status(f"{p['vm']}: {message}")
                    if worker.poll() is None:
                        worker.kill()
            if screen is not None and (now - last_draw >= 0.15 or all(p["code"] is not None for p in panes)):
                draw_shards(screen, panes, int(now - start))
                last_draw = now

    workers = []
    logs = []
    try:
        for i, vm in enumerate(vms):
            label = f"shard {i + 1}/{len(vms)}"
            status(f"Building the test bundle on {vm}…" if build else f"Starting {label} on {vm}…")
            logs.append((STATE / ("build.log" if build else f"shard-{i + 1}.log")).open("w", buffering=1))
            worker = sp.Popen(remote(addresses[vm], "/usr/bin/env", "PYTHONUNBUFFERED=1", f"BEND_TEST_SHARD_INDEX={i}",
                                     f"BEND_VM_PREBUILT={int(prebuilt)}",
                                     f"BEND_TEST_SHARD_COUNT={len(vms)}", "/bin/sh", "-c",
                                     'echo BEND_VM_TEST_PID=$$; exec /bin/bash "$@"' + (' >/dev/null' if build else ''), "test-runner",
                                     f"{GUEST_DIR}/scripts/test.sh", *args),
                              stdout=sp.PIPE, stderr=sp.STDOUT, text=True, errors="replace")
            reader = threading.Thread(target=output, args=(worker, i), daemon=True)
            workers.append((worker, reader))
            reader.start()
        if interactive:
            try:
                curses.wrapper(monitor)
            except curses.error:
                monitor()
        else:
            monitor()
        for i, p in enumerate(panes):
            status(f"{'Build' if build else f'Shard {i + 1}'}: {p['phase']} — {logs[i].name}")
            if p["code"] and p.get("diagnostic"):
                status(p["diagnostic"])
        result = 124 if any(p["code"] == 124 for p in panes) else next((p["code"] for p in panes if p["code"]), 0)
        if result:
            sys.exit(result if result > 0 else 128 - result)
    finally:
        for worker, _ in workers:
            if worker.poll() is None:
                worker.kill()
            worker.wait()
        for log in logs:
            log.close()


def draw_shards(screen, panes, elapsed):
    """Use columns on wide terminals and stacked panes on smaller screens."""
    size = os.get_terminal_size(sys.stdout.fileno())
    if size.lines and size.columns and curses.is_term_resized(size.lines, size.columns):
        curses.resizeterm(size.lines, size.columns)
    h, w = screen.getmaxyx()
    screen.erase()

    def write(y, x, text, width, attr=0):
        if 0 <= y < h and 0 <= x < w and width > 0:
            clean = "".join(c if c.isprintable() else " " for c in text)
            try:
                screen.addnstr(y, x, clean, min(width, w - x - 1), attr)
            except curses.error:
                pass  # Terminal may have resized between layout and paint.

    if all(p["total"] for p in panes):
        done, total = sum(p["done"] for p in panes), sum(p["total"] for p in panes)
        overall = f"{100 * done // total}% · {done}/{total} groups"
    else:
        known = sum(bool(p["total"]) for p in panes)
        overall = f"Discovering · {known}/{len(panes)} shards ready"
    write(0, 0, f"BEND TESTS   {overall}   {elapsed // 60:02}:{elapsed % 60:02} elapsed   Ctrl+C stops both VMs", w, curses.A_BOLD)
    wide = w >= 100
    for i, p in enumerate(panes):
        width = w // 2 if wide else w
        height = h - 2 if wide else (h - 2) // 2
        y, x = (2, i * width) if wide else (2 + i * height, 0)
        write(y, x, f"SHARD {i + 1}  ·  {p['vm']}", width - 1, curses.A_BOLD)
        progress = f"Group {p['current']}/{p['total']}  " if p["total"] else ""
        write(y + 1, x, progress + p["phase"], width - 1, curses.A_BOLD)
        rows = max(0, height - 3)
        for j, line in enumerate(list(p["lines"])[-rows:] if rows else []):
            write(y + 2 + j, x, line, width - 1)
    screen.refresh()


def wipe(tart):
    if not sys.stdin.isatty():
        sys.exit("Wipe needs an interactive terminal to choose what to remove.")
    guests = [g for g in json.loads(sp.check_output([tart, "list", "--format", "json"]))
              if g["Source"] == "local" and g["Name"] in GUESTS]
    ipsw = Path(os.environ.get("TART_HOME", Path.home() / ".tart")) / "cache/IPSWs" / IPSW_CACHE_NAME
    enrollment = [STATE / name for name in ("seeded", "known_hosts")]
    logs = [p for name in ("tart.log", "tart-2.log", "build.log", "shard-1.log", "shard-2.log") if (p := STATE / name).exists()]
    choices = {}
    if guests or any(p.exists() for p in enrollment):
        names = ", ".join(g["Name"] for g in guests)
        choices["1"] = f"Provisioned VMs, guest build caches and enrollment state{': ' + names if names else ''}"
    if ipsw.is_file():
        choices["2"] = f"Downloaded Apple restore image ({ipsw.stat().st_size / 1e9:.1f} GB; next restore downloads it again)"
    if logs:
        choices["3"] = "Runner logs: " + ", ".join(p.name for p in logs)
    if (STATE / CLT_CACHE).is_dir():
        choices["4"] = "Legacy Command Line Tools installer cache (no longer used)"
    if (STATE / "swiftpm-artifacts").is_dir():
        choices["5"] = "Cached SwiftPM binary artifacts"
    if (STATE / "swift-build").is_dir():
        choices["6"] = "Saved VM .build archive (next run compiles from scratch)"
    if not choices:
        status("Nothing to remove.")
        return

    def ask(prompt):
        print(prompt, file=sys.stderr, end="", flush=True)
        return sys.stdin.readline().strip().lower()

    status("Choose what to remove. The host SSH key is always kept.")
    for key, label in choices.items():
        print(f"  {key}. {label}", file=sys.stderr)
    answer = ask("Numbers separated by commas or spaces (Enter cancels): ")
    selected = set(answer.replace(",", " ").split())
    if not selected:
        status("Cancelled.")
        return
    if not selected.issubset(choices):
        sys.exit("Invalid selection. Nothing removed.")
    for key in sorted(selected):
        status(f"Selected: {choices[key]}")
    if ask("Delete the selected items? [y/N] ") not in ("y", "yes"):
        status("Cancelled.")
        return
    if "1" in selected:
        for guest in guests:
            vm = guest["Name"]
            if guest["Running"]:
                sp.run([tart, "stop", vm], check=True)
            sp.run([tart, "delete", vm], check=True)
        for path in enrollment:
            path.unlink(missing_ok=True)
    if "2" in selected:
        ipsw.unlink(missing_ok=True)
    if "3" in selected:
        for path in logs:
            path.unlink(missing_ok=True)
    if "4" in selected:
        shutil.rmtree(STATE / CLT_CACHE)
    if "5" in selected:
        shutil.rmtree(STATE / "swiftpm-artifacts")
    if "6" in selected:
        shutil.rmtree(STATE / "swift-build")
    status("Selected items removed.")


def stop_guest(tart, vm, proc=None):
    info = vm_info(tart, vm)
    if info and info["Running"]:
        status(f"Stopping {vm}…")
        sp.run([tart, "stop", vm], check=True)
        status(f"Stopped {vm}.")
    elif proc and proc.poll() is None:
        # An interrupt can arrive before Tart registers the VM as running.
        status(f"Stopping startup of {vm}…")
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except sp.TimeoutExpired:
            proc.kill()
            proc.wait()
        status(f"Stopped {vm}.")
    return info


def discard(tart, vm, proc=None):
    if stop_guest(tart, vm, proc):
        sp.run([tart, "delete", vm], check=True)
        status(f"Removed test clone {vm}.")


def main(args):
    if args in (["-h"], ["--help"]):
        print(HELP)
        return
    pair = args in (["setup", "--jobs", "2"], ["--jobs", "2"])
    if pair:
        args = args[:-2]
    elif args[:1] == ["--jobs"] or (args[:1] in (["setup"], ["stop"], ["wipe"], ["prefetch"], ["enroll"]) and len(args) != 1):
        sys.exit(HELP)
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        sys.exit("Tart tests require an Apple Silicon Mac.")
    prefixes = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]
    tart = tool("tart", prefixes)
    if not tart and args != ["prefetch"]:
        sys.exit(install_help(tool("brew", prefixes), tool("port", prefixes)))
    STATE.mkdir(parents=True, exist_ok=True)
    with (STATE / "lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            sys.exit("Another Bend VM operation is active.")
        if args == ["prefetch"]:
            if artifact := sparkle_archive(ROOT):
                status(f"Verified {artifact}")
            return
        if args == ["enroll"]:
            enroll(tart)
            return
        if args == ["wipe"]:
            wipe(tart)
            return
        vms = WORKERS if pair else WORKERS[:1]
        if args == ["stop"]:
            for vm in GUESTS:
                info = vm_info(tart, vm)
                if info and info["Running"]:
                    status(f"Stopping {vm}…")
                    sp.run([tart, "stop", vm], check=True)
            return
        boots = {}
        addresses = {}
        disposable = []
        try:
            # Recover leftovers from a killed runner; never reuse a worker disk.
            for vm in WORKERS:
                discard(tart, vm)
            base = vm_info(tart, BASE)
            if base and base["Running"]:
                sys.exit("The clean baseline must be stopped before cloning. Run scripts/test-vm.sh stop.")
            if not base:
                info = vm_info(tart, VM)
                if not info:
                    status("Preparing the clean baseline. After restore, provisioning will ask for confirmation before sudo.")
                    status(f"Restoring Apple macOS Tahoe 26.6.2 (cached when available) from {IPSW}")
                    sp.run([tart, "create", "--from-ipsw", IPSW, "--disk-size", "140", VM], check=True)
                    sp.run([tart, "set", VM, "--cpu", "4", "--memory", "8192"], check=True)
                    info = vm_info(tart, VM)
                managed = provision(tart, info)
                boot(tart, VM, boots, managed)
                sp.run([tart, "stop", VM], check=True)
                sp.run([tart, "rename", VM, BASE], check=True)
            if args == ["setup"]:
                status("Clean baseline ready.")
                return
            for vm in vms:
                status(f"Creating fresh test desktop {vm}…")
                disposable.append(vm)
                sp.run([tart, "clone", BASE, vm], check=True)
                addresses[vm] = boot(tart, vm, boots, (STATE / "seeded").exists())
            status("Syncing the working tree…")
            with tempfile.TemporaryDirectory(dir=STATE) as stage:
                snapshot(stage)
                artifact = sparkle_archive(stage)
                if artifact:
                    status("Seeding the verified Sparkle archive into each guest’s SwiftPM cache…")
                for vm in vms:
                    sync(addresses[vm], stage, artifact)
                # Custom SwiftPM options may select a different build path or configuration.
                prebuilt = not args or (len(args) == 2 and args[0] == "--filter")
                if prebuilt:
                    archive = build_archive(base or vm_info(tart, BASE), stage)
            if prebuilt:
                prepare_build(addresses, archive)
            run_shards(addresses, args, prebuilt=prebuilt)
        except KeyboardInterrupt:
            status("Interrupted.")
            sys.exit(130)
        finally:
            if VM in boots:
                stop_guest(tart, VM, boots[VM])
            for vm in disposable:
                discard(tart, vm, boots.get(vm))


def wait_ready(tart, vm, proc, log, managed=False):
    status(f"Waiting for SSH and the admin desktop on {vm}…")
    detail = "No guest address yet."
    start = time.monotonic()
    deadline = start + 180
    next_update = start + 15
    while time.monotonic() < deadline:
        if proc and proc.poll() is not None:
            sys.exit(f"Tart stopped during boot. See {log}")
        try:
            addr = sp.run([tart, "ip", vm], capture_output=True, timeout=5, text=True)
            if not addr.returncode and (ip := addr.stdout.strip()):
                check = ("d=/Library/BendTestVM; if test -f $d/failed; then cat $d/failed; exit 42; fi; "
                         "if ! test -f $d/ready; then "
                         "job=$(launchctl print system/org.bend.test-vm 2>/dev/null); "
                         "if echo \"$job\" | grep -Eq '^[[:space:]]*state = not running$' && "
                         "echo \"$job\" | grep -Eq '^[[:space:]]*last exit code = [1-9][0-9]*$'; then "
                         "tail -3 $d/setup.log; exit 42; fi; tail -1 $d/setup.log; exit 1; fi; " if managed else "")
                probe = sp.run(remote(ip, "/bin/sh", "-c", check + "stat -f '%Su' /dev/console"),
                               capture_output=True, timeout=6, text=True)
                if not probe.returncode and probe.stdout.strip() == "admin":
                    return ip
                detail = probe.stderr.strip() or probe.stdout.strip() or "The admin desktop is not logged in."
                if probe.returncode == 42:
                    sys.exit(f"Guest provisioning failed: {detail}. See /Library/BendTestVM/setup.log in {vm}.")
                if managed and probe.returncode == 1:
                    # Installing the toolchain can take longer than the normal boot window.
                    deadline = start + 3600
                if managed and probe.returncode == 0 and detail == "root":
                    detail = "Tools installed; waiting for the admin desktop after reboot."
                    deadline = min(deadline, time.monotonic() + 120)
                if "Permission denied" in detail or "Host key verification failed" in detail:
                    sys.exit(f"{detail}\nComplete SSH enrollment in README.md.")
        except sp.TimeoutExpired:
            pass
        now = time.monotonic()
        if now >= next_update:
            status(f"Still waiting ({int(now - start)}s elapsed): {detail}")
            next_update = now + 15
        time.sleep(1)
    else:
        sys.exit(f"Timed out waiting for {vm}: {detail} See {log}")


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except KeyboardInterrupt:
        status("Interrupted.")
        sys.exit(130)
    except sp.CalledProcessError as error:
        sys.exit(error.returncode)
