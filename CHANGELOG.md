# Changelog

User-facing changes to Bend, maintained with Changie. Versions use `MAJOR.MINOR.PATCH`.

Earlier prototype builds used the version `0.1` without a versioned changelog; `0.1.0` records that baseline.


## v0.4.0
### Added
- Open 1Password and Dark Reader settings directly from their cards in Extensions settings.
- Print the focused web page with Command-P or File → Print, using the native macOS print dialog and PDF options.
### Changed
- Refine the address popup with native Liquid Glass, a compact search field, lighter result typography, and subtler shortcut hints.
- Show Open Link in New Tab first in the right-click link menu.
### Fixed
- Use paired macOS selection colors for address autocomplete and selected suggestions, retaining full text contrast on selected rows.
- Open Foxy Gestures settings by supplying browser information and handling unavailable Firefox settings and permission checks. Explain the remaining limitation on default right-button gestures.
- Share cookies and website data across tabs and panes within each private window, keeping separate private windows isolated and clearing their data on closure.

## v0.3.0
### Added
- Choose whether the sidebar docks on the left or right in UI settings.
- Check for new Bend releases and offer an update button, with verified downloads, installation, and relaunch through Sparkle.
### Changed
- Keep untouched panes evenly sized when opening or moving panes, while preserving manually resized layouts.
- Show centered stacked favicons for multi-pane tabs, with the active pane in front. Round favicon corners in tabs and pane titles.
- Center stacked favicons vertically and quickly fade them when switching panes or adding a pane.
### Fixed
- Keep website favicons across browser restarts without loading background tabs. Private browsing icons remain in memory only.
- Show the packaged app version in About Bend instead of the old prototype label.
- Keep the Settings sidebar fixed in width when SwiftUI resets its native layout constraints.

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
