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
SPEED_WORKLOADS = {
    "typing": "Location typing",
    "finding": "Find in page",
    "unrelatedChange": "Unrelated store change",
}
MICRO_WORKLOADS = {
    "ranking": "History ranking (3,000 entries)",
    "sessionOpen": "Cold session open (150 tabs)",
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
                     last.get("storeChanges", "-"),
                     counts["mountedRootReplacements"], counts["browserPaneBodies"], counts["sidebarRowBodies"],
                     counts["shadowInvalidations"]])
    write_table(["Workload", "Wall (ms)", "Main CPU (ms)", "Store changes at 100", "Roots at 100",
                 "Pane bodies at 100", "Row bodies at 100", "Shadow invalidations at 100"], rows)


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


def speed_summary(path):
    print("### UI speed benchmarks\n")
    if not path.is_file():
        print("Speed report unavailable. See the **Measure tab UI speed** step.\n")
        return
    speed = json.loads(path.read_text(encoding="utf-8"))
    rows = []
    for key, label in SPEED_WORKLOADS.items():
        if key not in speed:
            continue
        item = speed[key]
        rows.append([
            label,
            f'{item.get("ms", 0.0):.2f}',
            f'{item.get("p95Ms", 0.0):.2f}',
            f'{item.get("totalMs", 0.0):.1f}',
            f'{item.get("storeChangesPerStep", 0.0):.1f}',
            f'{item.get("rowsPerStep", 0.0):.1f}',
            f'{item.get("paneBodiesPerStep", 0.0):.1f}',
            f'{item.get("mountedRootReplacementsPerStep", 0.0):.1f}',
            f'{item.get("shadowInvalidationsPerStep", 0.0):.1f}',
        ])
    if rows:
        write_table([
            "Workload", "Median (ms)", "p95 (ms)", "Total (ms)", "Store changes/step",
            "Row bodies/step", "Pane bodies/step", "Roots/step", "Shadow inv/step",
        ], rows)
    if "sidebarEdge" in speed:
        edge = speed["sidebarEdge"]
        step = (f'{edge.get("stepMs.p50", 0.0):.2f} / {edge.get("stepMs.p95", 0.0):.2f} / '
                f'{edge.get("stepMs.max", 0.0):.2f} ({int(edge.get("stepMs.count", 0))})')
        other = (f'{edge.get("otherMs.p50", 0.0):.2f} / {edge.get("otherMs.p95", 0.0):.2f} / '
                 f'{edge.get("otherMs.max", 0.0):.2f} ({int(edge.get("otherMs.count", 0))})')
        write_table([
            "Frame-paced drag", "Step frame p50/p95/max (ms)", "Other frame p50/p95/max (ms)",
            "Published held", "Row bodies/step", "Pane bodies/step", "Roots/step", "Shadow inv/step",
        ], [[
            "Sidebar edge (2 windows)", step, other, f'{edge.get("publishedWhileHeld", 0.0):.0f}',
            f'{edge.get("rowsPerStep", 0.0):.1f}', f'{edge.get("paneBodiesPerStep", 0.0):.1f}',
            f'{edge.get("mountedRootReplacementsPerStep", 0.0):.1f}',
            f'{edge.get("shadowInvalidationsPerStep", 0.0):.1f}',
        ]])
    micro = [
        [label, f'{speed[key].get("ms", 0.0):.2f}']
        for key, label in MICRO_WORKLOADS.items()
        if key in speed
    ]
    if micro:
        write_table(["Model / startup microbenchmark", "Median (ms)"], micro)


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
    speed_summary(args.report_dir / "speed.json")
    if scaling_error is not None:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
