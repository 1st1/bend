# Changelog

User-facing changes to Bend, maintained with Changie. Versions use `MAJOR.MINOR.PATCH`.

Earlier prototype builds used the version `0.1` without a versioned changelog; `0.1.0` records that baseline.


## v0.2.0
### Added
- Show the page URL when hovering its pane title.
- Private windows with Command-Shift-N, temporary history, isolated cookies and website storage for each pane, and per-extension private browsing permissions. Extension pages and popups are unavailable in private windows to keep website cookies isolated.
- Customize Option-click link destinations and open links in a new pane, tab, or window from the context menu.
- Show hidden-tab counts in small pills at the sidebar scroll edges.
### Changed
- Match favorite buttons to tab corners, hover backgrounds, and selected glass styling.
### Fixed
- Avoid unnecessary URL preview truncation and stale title URLs when hovering page links.
- Activate the browser when clicking a pane title in an inactive window.
- Preserve native window focus when clicking pane titles without interrupting pane dragging.
- Fade partially scrolled sidebar tabs smoothly at both edges, including beneath favorites.
- Honor the configured Option-click link destination on macOS 26 instead of WebKit’s default download action.
- Keep short notification sounds out of the media player; show unknown-duration and live playback after seven seconds.
- Retry favicon loading when in-page navigation changes the URL during an icon request.

## v0.1.1
### Changed
- Bend now requires macOS 26 or later, with Liquid Glass and extension support available on every supported macOS version.
### Fixed
- Prevent native extension connections from stalling background work on Macs with limited CPU resources.

## v0.1.0

Initial prototype baseline. Detailed change tracking begins with the next release.
