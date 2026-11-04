---
lat:
  require-code-mention: true
---
# Tests

Model, store, and navigation-delegate tests cover pane layouts, persistence, link routing, navigation resolution, and location-popup requests without loading external websites.

## Nested splits and closing

Splitting right and then below preserves leaf order. Closing panes collapses their parent branches, repairs focused-pane identity, and preserves the model’s final pane for the application layer to handle.

## Favicon discovery

[FaviconTests.swift](../Tests/BrowseTests/FaviconTests.swift) verifies relative icon URLs, deduplication, origin fallback, rejected URL schemes, and internal-page exclusion. A local WebKit document checks base URLs and standard icons taking priority over touch icons.

## Favicon fallback and cancellation

[FaviconTests.swift](../Tests/BrowseTests/FaviconTests.swift) verifies that invalid image data falls through to the next candidate and cancellation discards a successful response before it can update the pane.

## Favicon navigation reset

[FaviconTests.swift](../Tests/BrowseTests/FaviconTests.swift) verifies that a provisional navigation or opening an internal page clears the previous site's favicon.

## Link pane placement

Opening a link splits its source pane to the right even when another pane is focused, preserves neighboring branches and the source URL, and focuses the destination. The result survives serialization; missing source panes leave the tab unchanged.

## Command-click navigation

[LinkNavigationTests.swift](../Tests/BrowseTests/LinkNavigationTests.swift) verifies that WebKit's Command-left-click action opens a pane and cancels source navigation. Ordinary clicks, other buttons, and scripted navigation do not open panes; custom schemes remain blocked.

## Command-click new-window links

[LinkNavigationTests.swift](../Tests/BrowseTests/LinkNavigationTests.swift) verifies that Command-clicking a new-window link opens a pane without creating a tab. An ordinary new-window link still creates a tab.

## Session round trip

JSON encoding and decoding preserve the selected tab and nested layout. Restore validation rejects missing pages and selected tabs that do not exist.

## Pane geometry and insertion

[PaneGeometryTests.swift](../Tests/BrowseCoreTests/PaneGeometryTests.swift) verifies stable pane identities and exact frames through horizontal and nested vertical splits. Unaffected branches keep their frames, and closing restores the previous geometry.

## Pane geometry bounds

[PaneGeometryTests.swift](../Tests/BrowseCoreTests/PaneGeometryTests.swift) verifies that small viewports grow to fit minimum pane sizes, divider gaps remain consistent, and drag fractions respect both branches' bounds.

## Divider bounds

Divider updates clamp fractions to safe bounds and leave unrelated split nodes unchanged, preventing extreme drag values from making persisted panes disappear.

## Address resolution

Hostnames, explicit HTTPS, localhost, internal start pages, and search queries resolve correctly. Empty input and explicit non-web URL schemes are rejected, and query punctuation survives URL encoding.

## Location popup requests

[AddressRequestTests.swift](../Tests/BrowseTests/AddressRequestTests.swift) verifies that explicit location requests target the chosen pane, new blank panes prompt after focus changes, and link destinations do not prompt. Invalid pane IDs are ignored.

The store tests use an isolated temporary session-file path. They cover both split directions, blank tabs, new workspaces, and the replacement tab created after closing a workspace's last tab. Each automatic request must identify the newly focused pane.

Explicit requests for an existing pane focus that pane; invalid identities produce no request. Opening a link in a right-hand pane or a tab with a supplied URL must not request location entry. These tests exercise store events without instantiating the popup or loading WebKit pages.

## History recording

[HistoryTests.swift](../Tests/BrowseCoreTests/HistoryTests.swift) verifies web-only recording, credential stripping, merging of rapid repeated visits, title updates, and serialization that preserves valid history.

## History matching and completion

[HistoryTests.swift](../Tests/BrowseCoreTests/HistoryTests.swift) checks case- and accent-insensitive matching across titles and decoded URLs. Prefix completion handles explicit schemes and declines short, complete, or multiword queries.

## History ranking and learned choices

[HistoryTests.swift](../Tests/BrowseCoreTests/HistoryTests.swift) verifies recency, frequency, learned query choices, URL matching, and result limits so suggestions remain relevant and bounded.

## History removal and bounds

[HistoryTests.swift](../Tests/BrowseCoreTests/HistoryTests.swift) verifies eviction at the visit limit, removal from suggestions, and clearing visits and learned choices while retaining a valid model.

## History persistence and clearing

[HistoryStoreTests.swift](../Tests/BrowseTests/HistoryStoreTests.swift) verifies that visits and learned choices survive reloading, and that removal and clearing persist independently of session data.

## Unreadable history preservation

[HistoryStoreTests.swift](../Tests/BrowseTests/HistoryStoreTests.swift) verifies that corrupt history is reported and preserved during ordinary saves. Explicit clearing permits a valid empty history file to replace it.

## Completed navigation history

[HistoryStoreTests.swift](../Tests/BrowseTests/HistoryStoreTests.swift) checks that completed web navigation records once, title changes update existing history, and later URL changes add visits. Failed navigation and internal pages are excluded.
