#!/usr/bin/env python3
"""Measure Bend's offscreen WebKit tab footprint on macOS."""
import argparse
import http.server
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import threading

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "scripts/fixtures/tab-memory.html"
MARKER = "BEND_TAB_MEMORY "


class FixtureHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/":
            self.send_error(404)
            return
        payload = self.server.payload
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):
        pass


def sample(count, address, skip_build):
    command = [str(ROOT / "scripts/test.sh"), "--filter", "TabPerformanceTests/footprint"]
    if skip_build:
        command.append("--skip-build")
    env = dict(os.environ, BEND_TAB_MEMORY_COUNT=str(count), BEND_TAB_MEMORY_URL=address)
    with subprocess.Popen(command, cwd=ROOT, env=env, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, text=True) as process:
        measurements = []
        for line in process.stdout:
            if line.startswith(MARKER):
                measurements.append(json.loads(line[len(MARKER):]))
            else:
                print(line, end="", file=sys.stderr)
        status = process.wait()
    if status or len(measurements) != 1 or measurements[0]["tabs"] != count:
        raise RuntimeError(f"Expected one successful measurement for {count} tabs (exit {status})")
    return measurements[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tabs", type=int, default=30, help="largest sample size (default: 30)")
    parser.add_argument("--output", type=Path, help="also write the JSON report to this path")
    parser.add_argument("--skip-build", action="store_true", help="reuse an existing scripts/test.sh build")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("the benchmark requires macOS")
    if args.tabs <= 10:
        parser.error("--tabs must be greater than 10")

    with http.server.ThreadingHTTPServer(("127.0.0.1", 0), FixtureHandler) as server:
        server.payload = FIXTURE.read_bytes()
        thread = threading.Thread(target=server.serve_forever)
        thread.start()
        try:
            address = f"http://127.0.0.1:{server.server_port}/"
            samples = [sample(count, address, skip_build=args.skip_build or index > 0)
                       for index, count in enumerate((1, 10, args.tabs))]
        finally:
            server.shutdown()
            thread.join()

    print(f"{'Tabs':>4} {'WebContent':>10} {'Host MiB':>10} {'Web MiB':>10} {'Total MiB':>10}", file=sys.stderr)
    for row in samples:
        mib = 1024 ** 2
        print(f"{row['tabs']:4d} {row['webContentProcessCount']:10d} "
              f"{row['host']['physicalFootprintBytes'] / mib:10.2f} "
              f"{row['webContentFootprintBytes'] / mib:10.2f} "
              f"{row['totalFootprintBytes'] / mib:10.2f}", file=sys.stderr)
    report = json.dumps({
        "schemaVersion": 1, "macOS": platform.mac_ver()[0], "architecture": platform.machine(),
        "fixture": {"domCardsPerTab": 4096, "jsBytesPerTab": 12 * 1024 ** 2}, "samples": samples,
    }, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.write_text(report, encoding="utf-8")
    print(report, end="")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, ValueError) as error:
        sys.exit(f"bench-tab-memory: {error}")
