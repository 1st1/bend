---
lat:
  require-code-mention: true
---
# Session lifecycle tests

Tests verify mounted tab ownership, saved sessions, and reopening closed layouts.

See [[lat.md/architecture/session|Architecture and behavior]].

## Mounted tab switching

[TabSwitchingTests.swift](../../Tests/BrowseTests/TabSwitchingTests.swift) switches between real offscreen WebKit tabs and verifies native parents, document identity, unsaved input, and scroll position survive.

Document identity is checked with an injected JavaScript marker and unsaved DOM state, rather than a wall-clock-derived performance timestamp. The test uses local HTTP fixtures and ephemeral storage in a full-content window with a unified toolbar. It checks that the titlebar adds no extra top inset. Narrowing and widening columns verifies CSS viewport width matches the native web view, media queries switch layouts, and resize events fire. Both the HTTP request received by the fixture and JavaScript expose Safari-compatible product tokens plus Bend’s identifier. Unvisited tabs remain uncreated, hidden tabs keep their viewport and ignore other tabs' zoom, selection resizes the active host, and tab or background-pane closure removes retained content.

After switching back beneath a later-mounted hidden tab, the test verifies the inactive hosting root rejects hit tests and each visible pane's center resolves to its web view in None, Transparency, Outline, Outline glow, and Title tint modes. Switching highlight styles preserves the same WebView and native parent. On macOS 26 and later, the web surface reaches the pane’s top edge without a border inset. The test also sends a complete mouse gesture through the window: header press, drag across nine interior points of a real web view, and release. Each point activates the target preview; release rearranges the panes and removes the drag surface while preserving native WebKit parents, document identity, and unsaved input.

The pane and WebView frames stay identical across all focus styles, including Outline with the maximum gap and thickness; decorations consume no layout space.

## Session round trip

JSON encoding and decoding preserve the selected tab and nested layout. Restore validation rejects missing pages and selected tabs that do not exist.

## Reopening nested pane layouts

[ReopenTests.swift](../../Tests/BrowseTests/ReopenTests.swift) verifies exact split restoration without intervening changes and preserves new panes and divider fractions when reopening into an edited layout.

Restoration uses the nearest surviving ancestor when the original sibling is gone, retaining pane order and split direction.

## Closed pane and tab history

[ReopenTests.swift](../../Tests/BrowseTests/ReopenTests.swift) verifies a unified last-closed-first history, original workspace selection, focus, zoom clearing, saved URLs, and preservation of subsequent pane edits.

Closing a pane and then its tab reopens them in reverse order without duplicate pages or blank replacement tabs. Reopened layouts persist as valid sessions; closed-item history does not persist.

## Reopen boundaries and background closures

[ReopenTests.swift](../../Tests/BrowseTests/ReopenTests.swift) checks background extension closures, final-pane tab closure, invalid pane IDs, preservation of navigated replacement tabs, and the fifty-entry history limit.

## Flat tab list restoration

[ReopenTests.swift](../../Tests/BrowseTests/ReopenTests.swift) verifies legacy groups merge in order without losing selection, pane identities, layouts, or URLs. New tabs append to the list; close/reopen and saving preserve the single-group session.

## Tab performance baselines

The offscreen browser benchmark measures tab retention and the UI work of selecting tabs, editing a hidden tab's title, resizing the window, and scrolling the sidebar with 10 and 100 visited tabs.

Run `BEND_RUN_TAB_SCALING=1 scripts/test.sh --filter TabPerformanceTests/scaling` and save the line beginning with `BEND_TAB_SCALING` for comparison. Each workload applies eight operations to real AppKit and SwiftUI views. The JSON records restored, visited, and background-opened controller counts, store `objectWillChange` counts, per-step median and p95 latencies, mounted-root replacements, pane and row body evaluations, and shadow invalidation and draw counts. It also records wall and main-thread CPU time, cumulative host process CPU time, and 100-to-10 ratios. The process clock includes CPU consumed by threads that exited during the workload.

Lifecycle assertions cover lazy restoration, selection, loading without mounting a background tab, and controller cleanup. Timing is observational and varies with the machine and OS. Offscreen layers can record invalidations without drawing. The required suite discovers this test as a declared skip. Fixtures finish loading while their tabs are selected, before the measured workloads begin. Debug counters only collect during those workloads. Instruments can capture the matching `TabPerformance` signpost intervals.

## Tab memory footprint

The memory script measures the host process and WebKit processes serving a fixed set of loaded tabs in an offscreen Bend window.

Run `python3 scripts/bench-tab-memory.py --tabs 30 --output /tmp/bend-tab-memory.json` in a macOS GUI session with the native test toolchain. The script runs 1, 10, and the requested largest tab count in fresh test hosts. A loopback-only HTTP fixture builds 4,096 DOM cards and retains a fully written 12 MiB typed array per tab. Each sample waits for every document's readiness marker, then allows a one-second settling interval. The sampler records live controllers and attached views without waking hidden pages.

The JSON on stdout and summary on stderr report the number of distinct WebContent processes serving the fixture pages, plus raw physical-footprint bytes for the host and each of those processes from `proc_pid_rusage`. A test-only WebKit selector attributes launchd-parented services to their views. GPU, networking, and unattached process-cache services are outside the sample. Compare identical workloads on the same OS and hardware. The host footprint includes the Swift test runtime.

Bend CI publishes a tab performance summary and a downloadable artifact on main and on pull requests labeled `tab-perf`. The second native shard runs these benchmarks in separate steps using its existing Swift test build. The artifact includes the JSON reports, the Markdown summary, and the tested commit and runner toolchain. Benchmark measurements are informational.

## Tab speed benchmarks

[[Tests/BrowseTests/TabPerformanceTests.swift#TabPerformanceTests|TabPerformanceTests/speed]] measures 10-to-100 scaling for interactive UI, frame-paced drag, history ranking, and cold session opening when enabled.

Normal `./scripts/test.sh` runs discover `TabPerformanceTests/speed` as a declared skip unless `BEND_RUN_TAB_SPEED=1` or `BEND_SPEED_OUT` is set. When enabled, it compares `10 → 100` tabs across location typing (`10t/300h → 100t/3kh` in `AddressPanelController`), find-in-page typing (`WebSurfaceHost`), unrelated `@Published` store changes, frame-paced dual-window sidebar edge dragging (`LoopClock`), and cold session opening, plus `300 → 3,000` entry history ranking, without duplicating the four `scaling` workloads.

Find reports keystroke dispatch timings and elapsed time from the final keystroke until the expected match count appears. A missing result times out. Drag samples require visible movement of the sidebar edge at the midpoint and at least one measured drag frame.

It prints the `BEND_TAB_SPEED` JSON marker (`schemaVersion = 3`) and writes `BEND_SPEED_OUT` when set. CI runs it in the same `RUN_TAB_PERF == 'true'` shard-1 path as the scaling and memory benchmarks, and `scripts/report-tab-performance.py` summarizes `speed.json` into `tab-perf/summary.md`.

## Recent tab switching

[[Tests/BrowseTests/RecentTabSwitchingTests.swift#recentTabSwitching]] dispatches Control-Tab and Control-Shift-Tab through the native menu and verifies most-recently-used ordering.

It checks presses move only the highlight, a single press and release toggles between the two latest tabs, held Control walks deeper and wraps in both directions, releasing Control commits, Escape cancels, and closing a tab mid-cycle removes it.

## Recent tab shortcuts from focused content

[[Tests/BrowseTests/RecentTabSwitchingTests.swift#recentTabShortcutsFromFocusedContent]] focuses a view that claims every key equivalent, as web content does, and verifies Control-Tab and Control-Shift-Tab still cycle tabs.

It also checks other key equivalents still reach the focused view first.

## Tab switcher popup

[[Tests/BrowseTests/RecentTabSwitchingTests.swift#tabSwitcherPopup]] verifies the switcher stays hidden for a quick tap and appears while Control is held.

It checks rows follow recent order with the target highlighted, Shift moves the highlight, a Control-click on a row selects that tab and dismisses the popup, and losing key status cancels the cycle without switching.
