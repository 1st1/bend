#!/usr/bin/env python3
"""Extract the native tab benchmark and render an Actions run summary."""
import argparse
import json
import os
from pathlib import Path
import platform
import subprocess

SCALING_MARKER = "BEND_TAB_SCALING "
WORKLOADS = {
    "select": "Selection",
    "edit_title": "Hidden-title edit",
    "resize": "Resize",
    "scroll": "Sidebar scroll",
}


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def write_table(headers, rows):
    def row(cells):
        print("| " + " | ".join(map(str, cells)) + " |")

    row(headers)
    row(["---"] + ["---:"] * (len(headers) - 1))
    for cells in rows:
        row(cells)
    print()


def scaling_summary(path, output):
    with path.open(encoding="utf-8") as log:
        reports = [line[len(SCALING_MARKER):] for line in log if line.startswith(SCALING_MARKER)]
    if len(reports) != 1:
        raise ValueError(f"Expected one scaling report in {path}, found {len(reports)}")
    scaling = json.loads(reports[0])
    low, high = scaling["samples"]
    write_json(output / "scaling.json", scaling)
    print(f'### UI scaling at {low["tabs"]} → {high["tabs"]} tabs')
    print(f'\n{scaling["stepsPerWorkload"]} operations per workload.\n')
    write_table(["Tabs", "Initially live", "All visited", "Plus one background tab"], (
        [sample[key] for key in ("tabs", "initiallyLive", "visitedLive", "backgroundLive")]
        for sample in (low, high)
    ))
    rows = []
    for key, label in WORKLOADS.items():
        first, last = low["workloads"][key], high["workloads"][key]
        counts = last["counts"]
        rows.append([label,
                     f'{first["wallMilliseconds"]:.1f} → {last["wallMilliseconds"]:.1f}',
                     f'{first["mainThreadMilliseconds"]:.1f} → {last["mainThreadMilliseconds"]:.1f}',
                     counts["mountedRootReplacements"], counts["browserPaneBodies"], counts["sidebarRowBodies"],
                     counts["shadowInvalidations"]])
    write_table(["Workload", "Wall (ms)", "Main CPU (ms)", "Roots at 100", "Pane bodies at 100",
                 "Row bodies at 100", "Shadow invalidations at 100"], rows)


def memory_summary(path):
    print("### Memory footprint\n")
    if not path.is_file():
        print("Memory report unavailable. See the **Measure tab memory footprint** step.\n")
        return
    memory = json.loads(path.read_text(encoding="utf-8"))
    mib = 1024 ** 2
    write_table(["Tabs", "WebContent processes", "Host (MiB)", "WebContent (MiB)", "Total (MiB)"], (
        [s["tabs"], s["webContentProcessCount"], f'{s["host"]["physicalFootprintBytes"] / mib:.2f}',
         f'{s["webContentFootprintBytes"] / mib:.2f}', f'{s["totalFootprintBytes"] / mib:.2f}']
        for s in memory["samples"]
    ))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("test_log", type=Path)
    parser.add_argument("report_dir", type=Path)
    args = parser.parse_args()
    xcode = subprocess.check_output(["xcodebuild", "-version"], text=True).splitlines()
    metadata = {
        "commit": os.environ["GITHUB_SHA"],
        "runner": os.environ["RUNNER_NAME"],
        "runnerImage": os.environ.get("ImageOS"),
        "runnerImageVersion": os.environ.get("ImageVersion"),
        "macOS": platform.mac_ver()[0],
        "architecture": platform.machine(),
        "xcode": xcode,
    }
    write_json(args.report_dir / "provenance.json", metadata)
    print("## Tab performance\n")
    print(f'`{metadata["commit"]}` · macOS {metadata["macOS"]} ({metadata["architecture"]}) · {" ".join(xcode)}\n')
    try:
        scaling_summary(args.test_log, args.report_dir)
        scaling_error = None
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"UI scaling report unavailable. {error}\n")
        scaling_error = error
    memory_summary(args.report_dir / "memory.json")
    if scaling_error is not None:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
