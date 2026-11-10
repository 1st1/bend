#!/usr/bin/env python3
"""Run every discovered test, isolating AppKit's process-global native state."""
import os
import re
import signal
import subprocess
import sys


def run(command, timeout=180):
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               text=True, start_new_session=True)
    try:
        output, _ = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            output, _ = process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            output, _ = process.communicate()
        return 1, output + f"\nTest process exceeded {timeout} seconds.\n"
    return process.returncode, output


def main(command):
    # Discovery builds once with exactly the same SDK flags as execution.
    listing = subprocess.run([arg for arg in command if arg != "--no-parallel"] + ["list"],
                             capture_output=True, text=True)
    sys.stdout.write(listing.stderr)
    if listing.returncode:
        sys.stdout.write(listing.stdout)
        return listing.returncode
    names = [line.strip() for line in listing.stdout.splitlines() if line.strip()]
    if not names or len(set(names)) != len(names) or any(
            not re.fullmatch(r"Browse(?:Core)?Tests[./].+\(.*\)", name) for name in names):
        sys.stderr.write("Unrecognized or empty test inventory:\n" + listing.stdout)
        return 1
    core = [name for name in names if name.startswith(("BrowseCoreTests.", "BrowseCoreTests/"))]
    native = [name for name in names if name.startswith(("BrowseTests.", "BrowseTests/"))]
    # SwiftPM's execution filters omit the module prefix shown by `list`.
    # Match function boundaries, and reject ambiguous inventory names.
    functions = {name: name.rsplit("/", 1)[-1].rsplit(".", 1)[-1].split("(", 1)[0] for name in names}
    if len(set(functions.values())) != len(names) or len(core) + len(native) != len(names):
        sys.stderr.write("Ambiguous test inventory; cannot guarantee complete isolated execution.\n")
        return 1
    groups = ([core] if core else []) + [[name] for name in native]
    failures = []
    print(f"Discovered {len(names)} tests; running {len(native)} native tests in separate processes.", flush=True)
    for index, group in enumerate(groups, 1):
        label = group[0] if len(group) == 1 else f"{len(group)} core tests"
        print(f"\n[{index}/{len(groups)}] {label}", flush=True)
        pattern = r"(^|[./])(?:" + "|".join(re.escape(functions[name]) for name in group) + r")(\(|$)"
        code, output = run(command + ["--skip-build", "--filter", pattern])
        print(output, end="", flush=True)
        # A successful process with an unmatched filter must not silently omit
        # coverage. Disabled tests are still discovered and reported as skipped.
        summaries = re.findall(r"Test run with (\d+) tests?", output)
        matched = sum(map(int, summaries))
        if code or matched != len(group):
            failures.append(label)
            print(f"FAILED: exit={code}, expected {len(group)} tests, reported {matched}.", flush=True)
    if failures:
        print("\nFailed groups:\n" + "\n".join(failures))
        return 1
    print(f"\nAll {len(names)} discovered tests completed successfully (including declared skips).")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
