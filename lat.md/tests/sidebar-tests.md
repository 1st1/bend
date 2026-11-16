---
lat:
  require-code-mention: true
---
# Sidebar tests

Tests verify sidebar placement, sizing, floating presentation, and tab ordering.

See [[lat.md/architecture/sidebar|Architecture and behavior]].

## Floating sidebar interaction

[FloatingSidebarTests.swift](../../Tests/BrowseTests/FloatingSidebarTests.swift) exercises edge reveal, hover retention, delayed dismissal, tab selection through native hit testing, pinning, fullscreen edge geometry, and deactivation.

The same native interaction checks run on both window edges, including overlay hit routing and traffic-light access.

The mounted-window test verifies the canvas frame and retained WebView identities remain unchanged while the panel opens, switches tabs, and closes. The panel reaches the top inset behind the traffic lights, which remain native hit targets. The top-row pin button receives clicks above the pane header; covered pane headers cannot begin a pane drag. Exit and reentry are delivered in one main-actor turn before awaiting the dismissal interval, so cancellation does not depend on the runner resuming a short sleep before the deadline.

## Sidebar tab reordering

[ReopenTests.swift](../../Tests/BrowseTests/ReopenTests.swift) exercises upward and downward tab moves, invalid and redundant drops, unchanged selection and live views, and persistence of tab order and pane layouts.

## Sidebar resize tracking and restoration

[PaneResizingTests.swift](../../Tests/BrowseTests/PaneResizingTests.swift) drives the sidebar edge in a native window, checking repeated pointer positions, reversals, bounds, repeated drags, pane resizing, live controllers, hide/show, and saved-width restoration.

Both sidebar positions exercise mirrored native dragging. Missing position defaults to left; saved position restores and is shared with secondary and private stores. The allowed range is 200–400 points with a 250-point default. Existing in-range widths remain unchanged; out-of-range widths clamp and nonfinite stored values use the default.

## Sidebar visibility animation

[PaneResizingTests.swift](../../Tests/BrowseTests/PaneResizingTests.swift) samples native canvas geometry during sidebar collapse and restoration, checking intermediate positions, final bounds, reversal, and unchanged live WebView/controller identity.

Both sidebar positions are covered. Disabling animations applies the final layout immediately without intermediate frames. Changing sides retains the mounted canvas, native WebView parent, and unsaved form state while moving the canvas to the opposite edge.

## Native sidebar tab dragging

[PaneTransferTests.swift](../../Tests/BrowseTests/PaneTransferTests.swift) sends window mouse events through the glass sidebar to verify repeated tab reordering, stable insertion targets, Escape and outside cancellation, selection, recovery from a missing release, and separate close-button handling.

## Sidebar overflow counts

[[Tests/BrowseTests/SidebarScrollStatusTests.swift#sidebarOverflowCounts]] verifies counts of fully hidden tabs above and below the sidebar viewport, excluding partially visible rows even at fractional scroll positions.

Coverage includes exact row boundaries, the favorites inset, resizing, insertion and removal, overscroll, empty lists, and unmeasured viewports. Counts account for the fixed toolbar and floating media player covering the scroll viewport.

## Sidebar toolbar fade

[[Tests/BrowseTests/SidebarScrollStatusTests.swift#sidebarToolbarFade]] checks that the tab viewport extends beneath the toolbar on both sides in docked and floating modes, with initial clearance keeping the first row below the fade.

Scrolling moves rows through the toolbar area. Adding favorites preserves the viewport and increases the first-row clearance for the fixed grid. Existing floating-sidebar interaction tests cover toolbar and tab click routing.

## Favorites with no regular tabs

[[Tests/BrowseTests/SidebarScrollStatusTests.swift#favoritesWithoutRegularTabs]] verifies the favorites grid keeps three full-width columns when Command-W closes the last regular tab, with only favorite tabs remaining.

The native-window regression covers both sidebar sides, docked and floating layouts, adding and closing a replacement regular tab, and restoring the favorites-only session from disk.
