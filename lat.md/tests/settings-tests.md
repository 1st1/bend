---
lat:
  require-code-mention: true
---
# Settings tests

Tests verify application preferences and per-website settings, storage, and zoom.

See [[lat.md/architecture/settings|Architecture and behavior]].

## UI preference persistence

[AddressRequestTests.swift](../../Tests/BrowseTests/AddressRequestTests.swift) verifies legacy session defaults, preference persistence across store recreation, preserved tab identity, and numeric bounds and nonfinite-value handling.

Window/header appearances persist independently, including the solid header color and style, preserve legacy defaults, and support resetting both appearances. Top- and bottom-rim clipping default independently for legacy sessions, persist fractional values, delegate through secondary windows, and clamp invalid input. Sessions containing retired custom separator settings still load without affecting the clipping defaults or tabs.

Highlight settings preserve separate colors, outline gap and width, intensity, spread, and mode across restart, including None mode and retained title-tint color and intensity; absent highlight settings use None. Older records without an outline gap receive the default gap. Older records without spread decode with their previous intensity-derived radius; records without title-tint fields receive the default color and intensity. Invalid colors and nonfinite numeric values normalize to defaults, and out-of-range values are bounded.

## Live window glass preferences

[AddressRequestTests.swift](../../Tests/BrowseTests/AddressRequestTests.swift) verifies style and tint update on the existing native window glass, header changes leave it alone, and reset clears tint without replacing content.

## Page zoom shortcuts

[PageZoomTests.swift](../../Tests/BrowseTests/PageZoomTests.swift) invokes native menu shortcuts against two web panes to verify zoom-in aliases, zoom-out, reset, focused-pane isolation, bounds, and disabled internal or hidden pages.

Changing page zoom preserves an injected document marker and edited form contents and leaves the independent pane-maximizing layout mode untouched. Native magnification is enabled, scales only one pane, and remains independent of keyboard page zoom. The test applies magnification through WebKit’s public API; physical trackpad gesture delivery requires a manual check.

## Settings close shortcut

[BrowserWindowTests.swift](../../Tests/BrowseTests/BrowserWindowTests.swift) verifies Command-W closes the focused Settings window without changing browser panes, still closes a focused browser pane, and cancels a new tab from its address popup.

The test dispatches real menu key equivalents with an explicit focused-window provider, avoiding dependence on desktop activation in a headless test host. The native Settings window hides the centered window title and keeps full-size content, with a transparent titlebar before content scrolls beneath the section heading.

## Settings section toolbar

[BrowserWindowTests.swift](../../Tests/BrowseTests/BrowserWindowTests.swift) verifies that the native Settings toolbar contains the section title and that sidebar selection updates the window title for UI, Websites, Extensions, and Development.

The toolbar test verifies targeted Extensions presentation in fresh, visible, and reopened Settings windows, and that general presentation preserves the current selection. It also verifies reopening centers Settings on each available screen after moving it offscreen. It scrolls overflowing detail content beneath the stationary title and back to the top, checking that native titlebar transparency changes with the overlap. It also verifies native toolbar insets and fixed width bounds across all sections while allowing vertical resizing. The visible sidebar stays 200 points wide across section changes, including attempts to move the native divider in both directions; assertions exclude OS-dependent margins on the native split-item wrapper.

## Website setting identity

[WebsiteSettingsTests.swift](../../Tests/BrowseCoreTests/WebsiteSettingsTests.swift) verifies hostname normalization, path/scheme/port sharing, distinct subdomains, internal-page exclusion, and valid zoom bounds.

## Website settings transactions

[WebsiteSettingsTests.swift](../../Tests/BrowseCoreTests/WebsiteSettingsTests.swift) verifies default and override persistence, atomic rollback after an injected write failure, retry, deletion, and invalid-value rejection.

## Website settings storage protection

[WebsiteSettingsTests.swift](../../Tests/BrowseCoreTests/WebsiteSettingsTests.swift) verifies corrupt files are preserved and unrelated or newer databases are rejected without adopting their contents.

## Website security migration

[[Tests/BrowseCoreTests/WebsiteSettingsTests.swift#websiteSecurityMigration]] verifies legacy zoom settings survive migration, new security preferences start with compatible defaults, and all four Boolean choices persist after reopening.

## Website security preferences

[[Tests/BrowseTests/WebsiteSettingsTests.swift#websiteSecurityPreferences]] verifies real website JavaScript is disabled and re-enabled on navigation, fraud warnings and cookie policy update live, and HTTP warnings select WebKit’s user-mediated fallback.

Each navigation waits for its expected title as well as its URL and loading state, so asynchronous title delivery cannot be mistaken for disabled page JavaScript.

## Website zoom navigation and sharing

[WebsiteSettingsTests.swift](../../Tests/BrowseTests/WebsiteSettingsTests.swift) verifies persisted zoom across panes, windows, and store recreation, using local HTTP pages with redirects, iframe loads, and back/forward navigation.

Default changes, explicit 100% overrides, individual/all resets, and history clearing preserve the intended website preference boundaries. Existing pages update without reloading; internal pages stay at 100%.

## Website zoom during provisional navigation

[WebsiteSettingsTests.swift](../../Tests/BrowseTests/WebsiteSettingsTests.swift) verifies a delayed destination cannot resize the outgoing page before commit, and a failed navigation keeps its zoom and settings ownership.

Live settings changes during the delay affect the visible source document; the destination’s latest preference applies at commit. Redirects never apply an intermediate host’s preference to the outgoing document.

## Website settings failure recovery

[WebsiteSettingsTests.swift](../../Tests/BrowseTests/WebsiteSettingsTests.swift) verifies unreadable settings surface an error without overwriting the file, and retry restores persistence after storage is repaired.
