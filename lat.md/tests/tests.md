# Tests

Model, store, and navigation-delegate tests cover pane layouts, persistence, link routing, navigation resolution, and location-popup requests without loading external websites.

Agents should prefer the local VM for Swift tests so native windows and focus changes stay off the developer's desktop. Use `--filter NAME` for a focused run or `--jobs 2` for the full suite. If the VM is unavailable or busy, ask before running native tests on the host.

```sh
./scripts/test-vm.sh --jobs 2
lat check
```

[[scripts/test.sh]] compiles with BEND_TESTING to replace AI Keychain access with process-local memory, preventing password prompts and access to saved accounts. It uses the installed SDK's version in the linked binary, matching the app and CI. Plain SwiftPM linking can select older AppKit compatibility behavior, including different sidebar constraints. With no arguments, [[scripts/test-all.py]] discovers the full inventory, runs core tests together, SDK tests together, and runs each native test in a fresh process. This isolates AppKit's global menus, focus, and animation workers; accumulated native animations can exhaust dispatch workers in a long-lived test host. Every discovered test must report a result or its declared skip, and failed or timed-out processes fail the run. A crashed process, missing result, or unmatched filter is recorded as a failure while all later groups still execute; the final summary lists every failed group. Arguments such as `--filter` run a focused selection directly.

Run [test-swiftlint.sh](../../scripts/test-swiftlint.sh) to check production Swift on its own. [[lat.md/tests/build-tests#Production Swift lint]] describes the rules enforced by the full local suite and native CI.

For desktop isolation, [test-vm.sh](../../scripts/test-vm.sh) runs the suite over SSH in disposable macOS guests. [[scripts/test-vm.py#provision|Offline provisioning]] and the [first-boot job](../../scripts/test-vm-firstboot.sh) prepare Apple's Tahoe restore with a test desktop and toolchain. [[scripts/test-vm.py#main|The runner]] saves this stopped guest as the baseline. Each invocation clones it once per shard; [[scripts/test-vm.py#sync|working-tree sync]] and testing only touch the clones.

For the default build configuration, [[scripts/test-vm.py#prepare_build]] builds on one worker, saves its `.build` to the host before tests, and gives every shard a private copy. [[scripts/test-vm.py#build_archive]] distinguishes exact source snapshots from compatible incremental inputs. No test-run changes are written back.

[[scripts/test-vm.py#run_shards]] monitors each guest command independently so a busy shard cannot hide a stalled peer. [[scripts/test-vm-lifecycle.py#WatchdogTests]] covers stale SSH sessions, quiet but live tests, and idle and wall-time limits. [[scripts/test-vm-lifecycle.py#LifecycleTests]] covers clone cleanup on failures and interrupts and selective removal of cached resources.

Set `BEND_TEST_SHARD_INDEX` (zero-based) and `BEND_TEST_SHARD_COUNT` together to run one part of the full suite. The runner validates the full inventory, then sorts and partitions execution groups round-robin so shards are disjoint and the model and SDK groups stay intact.

- [[build-tests|Build and signing]] — Development builds, distribution signing, and isolated application profiles.
- [[updates-tests|Application updates]] — Signed application updates, launch scheduling, and updater presentation.
- [[windows-tests|Browser windows]] — Native application windows, fullscreen transitions, and window dragging.
- [[media-tests|Media playback]] — Sidebar media controls, source ownership, and exclusive playback.
- [[sidebar-tests|Sidebar]] — Sidebar placement, sizing, floating presentation, and tab ordering.
- [[privacy-tests|Privacy]] — Private browsing lifetimes, storage isolation, and privacy preferences.
- [[favorites-tests|Favorites]] — Shared favorite tabs and per-account Google destinations.
- [[pane-controls-tests|Pane controls]] — Pane toolbar appearance, navigation controls, pins, and return destinations.
- [[pane-materials-tests|Pane materials]] — Pane surfaces, glass ownership, shadows, and rendering boundaries.
- [[pane-layout-tests|Pane layout]] — Tiling geometry, automatic sizing, and layout animation.
- [[pane-transfers-tests|Pane transfers]] — Pane and tab drag operations within and between browser windows.
- [[session-tests|Session lifecycle]] — Mounted tab ownership, saved sessions, and reopening closed layouts.
- [[web-pages-tests|Web pages]] — WebKit ownership, page printing, and JavaScript dialogs.
- [[downloads-tests|Downloads]] — Download transfers, persistent records, progress, and destination handling.
- [[developer-tools-tests|Developer tools]] — Web inspection and opt-in native input diagnostics.
- [[favicons-tests|Favicons]] — Page icon discovery, persistent caching, and sidebar presentation.
- [[external-links-tests|External links]] — Default browser registration, local documents, and external application consent.
- [[settings-tests|Settings]] — Application preferences and per-website settings, storage, and zoom.
- [[find-tests|Find in page]] — Native find controls and WebKit text matching.
- [[history-tests|History]] — Navigation recording, local persistence, history browsing, and suggestion ranking.
- [[address-entry-tests|Address entry and search]] — Address resolution, search providers, and the location popup.
- [[commands-tests|Command panel]] — Command discovery, validation, and execution in the command popup.
- [[link-navigation-tests|Link navigation]] — Modified clicks, link context menus, and destination previews.
- [[extension-hosting|Extensions]] — Lifecycle, compatibility, catalog, diagnostics, and updates.
- [[pane-sleep-tests|Pane sleeping]] — Eligibility, release, restoration, and persistent exceptions.
- [[ai-tests|Native AI chat]] — Streaming, conversation isolation, Gateway connection, and pane tool boundaries.

The [[lat.md/ai-sdk/sdk-tests|AI SDK tests]] cover provider parsing, streaming integrity, agent orchestration, and opt-in loopback networking.
