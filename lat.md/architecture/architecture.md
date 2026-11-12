# Architecture

Bend is a native macOS prototype combining SwiftUI browser chrome, AppKit windows, and system WebKit pages in nested tiling layouts.

- [[build|Build and signing]] — Development builds, distribution signing, and isolated application profiles.
- [[updates|Application updates]] — Signed application updates, launch scheduling, and updater presentation.
- [[windows|Browser windows]] — Native application windows, fullscreen transitions, and window dragging.
- [[media|Media playback]] — Sidebar media controls, source ownership, and exclusive playback.
- [[sidebar|Sidebar]] — Sidebar placement, sizing, floating presentation, and tab ordering.
- [[privacy|Privacy]] — Private browsing lifetimes, storage isolation, and privacy preferences.
- [[favorites|Favorites]] — Shared favorite tabs and per-account Google destinations.
- [[pane-controls|Pane controls]] — Pane toolbar appearance, navigation controls, pins, and return destinations.
- [[pane-materials|Pane materials]] — Pane surfaces, glass ownership, shadows, and rendering boundaries.
- [[pane-layout|Pane layout]] — Tiling geometry, automatic sizing, and layout animation.
- [[pane-transfers|Pane transfers]] — Pane and tab drag operations within and between browser windows.
- [[session|Session lifecycle]] — Mounted tab ownership, saved sessions, and reopening closed layouts.
- [[web-pages|Web pages]] — WebKit ownership, page printing, and JavaScript dialogs.
- [[downloads|Downloads]] — Download transfers, persistent records, progress, and destination handling.
- [[developer-tools|Developer tools]] — Web inspection and opt-in native input diagnostics.
- [[favicons|Favicons]] — Page icon discovery, persistent caching, and sidebar presentation.
- [[external-links|External links]] — Default browser registration, local documents, and external application consent.
- [[settings|Settings]] — Application preferences and per-website settings, storage, and zoom.
- [[find|Find in page]] — Native find controls and WebKit text matching.
- [[history|History]] — Navigation recording, local persistence, history browsing, and suggestion ranking.
- [[address-entry|Address entry and search]] — Address resolution, search providers, and the location popup.
- [[commands|Command panel]] — Command discovery, validation, and execution in the command popup.
- [[link-navigation|Link navigation]] — Modified clicks, link context menus, and destination previews.
- [[extensions|Extensions]] — Lifecycle, compatibility, catalog, diagnostics, and updates.
