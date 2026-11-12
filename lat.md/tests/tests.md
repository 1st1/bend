# Tests

Model, store, and navigation-delegate tests cover pane layouts, persistence, link routing, navigation resolution, and location-popup requests without loading external websites.

Run the test suite and documentation validation from the repository root:

```sh
./scripts/test.sh
lat check
```

[[scripts/test.sh]] uses the installed SDK's version in the linked binary, matching the app and CI. Plain SwiftPM linking can select older AppKit compatibility behavior, including different sidebar constraints. With no arguments, [[scripts/test-all.py]] discovers the full inventory, runs core tests together, and runs each native test in a fresh process. This isolates AppKit's global menus, focus, and animation workers; accumulated native animations can exhaust dispatch workers in a long-lived test host. Every discovered test must report a result or its declared skip, and failed or timed-out processes fail the run. A crashed process, missing result, or unmatched filter is recorded as a failure while all later groups still execute; the final summary lists every failed group. Arguments such as `--filter` run a focused selection directly.

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
