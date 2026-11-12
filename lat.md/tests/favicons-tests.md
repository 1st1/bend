---
lat:
  require-code-mention: true
---
# Favicons tests

Tests verify page icon discovery, persistent caching, and sidebar presentation.

See [[lat.md/architecture/favicons|Architecture and behavior]].

## Favicon discovery

[FaviconTests.swift](../../Tests/BrowseTests/FaviconTests.swift) verifies relative icon URLs, deduplication, origin fallback, rejected URL schemes, and internal-page exclusion. A local WebKit document checks base URLs and standard icons taking priority over touch icons.

## Persistent favicon restoration

[[Tests/BrowseTests/FaviconTests.swift#persistentFaviconRestoration]] loads a real favicon, restores a saved profile, and renders both stacked icons without creating pane controllers; a live pane starts with its cached icon and refreshes it through WebKit.

Regular windows share the cache while separate profiles do not. Private panes cannot read regular icons, and successful private icon loads, history clearing, and teardown leave the regular cache unchanged and create no private files. Clearing regular history removes persisted icons.

## Favicon cache bounds and recovery

[[Tests/BrowseTests/FaviconTests.swift#faviconCacheBoundsAndRecovery]] checks cached pixel colors, origin normalization without URL secrets, scheme/host/port isolation, oldest-entry eviction, corrupt snapshots and image rejection, and usable in-memory icons after write failures.

## Stacked favicon transitions

[[Tests/BrowseTests/FaviconTests.swift#stackedFaviconTransitions]] verifies insertion and focus swaps fade changed icons, while initial mounting, unchanged updates, Reduce Motion, and returning to one pane leave no unwanted animations.

## Sidebar favicons

[FaviconTests.swift](../../Tests/BrowseTests/FaviconTests.swift) loads an icon through a local HTTP fixture and checks the mounted sidebar image updates to that exact favicon, resets for a native page, and leaves unvisited tabs uninstantiated.

Mounted front images remain 16×16 points and rear images 12×12 points in a fixed 24×28-point slot across sidebar widths. A three-pane tab renders exactly two horizontally centered icons with their combined bounds vertically centered in the slot, updates the front icon on focus changes, and keeps number labels out of the icon stack. Rendered pixels must darken toward the front icon’s overlap, verifying the contact shadow is visible. Closing panes updates the rear icon and pane count, then hides the rear icon for a single pane. Opaque oversized rasters exercise clipping; `BEND_SIDEBAR_SNAPSHOT` optionally captures the stack for visual inspection.

## Favicon fallback and cancellation

[faviconFallback](../../Tests/BrowseTests/FaviconTests.swift) verifies invalid images fall through to a valid WebKit-rasterized icon and cancellation discards a delayed valid response before it can update the pane.

## Favicon request security

[faviconRequestSecurity](../../Tests/BrowseTests/FaviconTests.swift) verifies icon loading respects image CSP, rejects redirects outside that policy, requires cross-origin CORS permission, and resists page overrides of image and canvas functions.

Local HTTP fixtures record requests so the test distinguishes blocked network access from a failed decode. CSP denial covers both declared icons and the origin fallback, including a second loopback server. Allowed images still produce a native icon.

## Favicon history navigation

[[Tests/BrowseTests/FaviconTests.swift#faviconHistoryNavigation]] changes a playing page's URL through the History API while its first icon request is pending, verifying favicon loading recovers without a full document navigation.

## Favicon navigation reset

[FaviconTests.swift](../../Tests/BrowseTests/FaviconTests.swift) verifies same-origin links, reloads, and address entry preserve the icon without a placeholder, while redirects to another origin and internal pages clear it.

A delayed local HTTP response checks that the icon stays visible during loading and is replaced after a successful refresh. CSP-blocked refreshes retain the last same-origin icon; late results cannot restore it after leaving the origin. Origin comparison includes scheme, hostname, and effective port.
