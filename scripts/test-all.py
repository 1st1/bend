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


def main(command, shard_index=0, shard_count=1):
    if not 0 <= shard_index < shard_count:
        print("Test shard index must be in the range 0..<shard count.", file=sys.stderr)
        return 1

    # Discovery builds once with exactly the same SDK flags as execution.
    list_args = ["list", "--skip-build"] if os.environ.get("BEND_VM_PREBUILT") == "1" else ["list"]
    listing = subprocess.run([arg for arg in command if arg != "--no-parallel"] + list_args,
                              stdout=subprocess.PIPE, text=True)
    if listing.returncode:
        sys.stdout.write(listing.stdout)
        return listing.returncode
    names = sorted(line.strip() for line in listing.stdout.splitlines() if line.strip())
    if not names or len(set(names)) != len(names) or any(
            not re.fullmatch(r"(?:Browse(?:Core)?Tests|AITests)[./].+\(.*\)", name) for name in names):
        sys.stderr.write("Unrecognized or empty test inventory:\n" + listing.stdout)
        return 1
    core = [name for name in names if name.startswith(("BrowseCoreTests.", "BrowseCoreTests/"))]
    sdk = [name for name in names if name.startswith(("AITests.", "AITests/"))]
    native = [name for name in names if name.startswith(("BrowseTests.", "BrowseTests/"))]
    # SwiftPM's execution filters omit the module prefix shown by `list`.
    # Match function boundaries, and reject ambiguous inventory names.
    functions = {name: name.rsplit("/", 1)[-1].rsplit(".", 1)[-1].split("(", 1)[0] for name in names}
    if len(set(functions.values())) != len(names) or len(core) + len(sdk) + len(native) != len(names):
        sys.stderr.write("Ambiguous test inventory; cannot guarantee complete isolated execution.\n")
        return 1
    groups = ([core] if core else []) + ([sdk] if sdk else []) + [[name] for name in native]
    if shard_count > len(groups):
        print("Test shard count exceeds the number of execution groups.", file=sys.stderr)
        return 1
    groups = groups[shard_index::shard_count]
    selected = sum(map(len, groups))
    failures = []
    print(f"Discovered {len(names)} tests. Shard {shard_index + 1}/{shard_count} will run "
          f"{selected} tests in {len(groups)} isolated groups.", flush=True)
    for index, group in enumerate(groups, 1):
        label = group[0] if len(group) == 1 else f"{len(group)} model/SDK tests"
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
    print(f"\nAll {selected} tests in this shard completed successfully (including declared skips).")
    return 0


if __name__ == "__main__":
    shard_index = os.environ.get("BEND_TEST_SHARD_INDEX")
    shard_count = os.environ.get("BEND_TEST_SHARD_COUNT")
    if (shard_index is None) != (shard_count is None):
        sys.exit("Set BEND_TEST_SHARD_INDEX and BEND_TEST_SHARD_COUNT together.")
    if shard_index is None:
        sys.exit(main(sys.argv[1:]))
    try:
        index, count = int(shard_index), int(shard_count)
    except ValueError:
        sys.exit("BEND_TEST_SHARD_INDEX and BEND_TEST_SHARD_COUNT must be integers.")
    sys.exit(main(sys.argv[1:], index, count))
