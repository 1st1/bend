---
lat:
  require-code-mention: true
---
# Pane layout tests

Tests verify tiling geometry, automatic sizing, and layout animation.

See [[lat.md/architecture/pane-layout|Architecture and behavior]].

## Nested splits and closing

Splitting right and then below preserves leaf order. Closing panes collapses their parent branches, repairs focused-pane identity, and preserves the model’s final pane for the application layer to handle.

## Equal automatic pane sizes

[[Tests/BrowseCoreTests/AutomaticPaneSizingTests.swift#equalAutomaticPaneSizes]] verifies equal widths and heights after repeated splits, closing, reopening, and persistence, with divider gaps excluded and perpendicular subdivisions kept within their column.

## Equal pane sizes after transfers

[[Tests/BrowseCoreTests/AutomaticPaneSizingTests.swift#equalPaneSizesAfterTransfers]] checks equal geometry after cross-tab drops at every edge, same-tab reordering, and joining a whole tab through the sidebar.

## Manual pane sizing intent

[[Tests/BrowseCoreTests/AutomaticPaneSizingTests.swift#manualPaneSizingIntent]] verifies that resizing an automatic three-pane row leaves unrelated boundaries in place, later insertions preserve chosen sizes, and returning to half remains manual after restart.

## Legacy pane sizing migration

[[Tests/BrowseCoreTests/AutomaticPaneSizingTests.swift#legacyPaneSizingMigration]] decodes layouts without sizing metadata and checks that half splits become automatic while unequal legacy fractions remain fixed on insertion.

## Pane geometry and insertion

[PaneGeometryTests.swift](../../Tests/BrowseCoreTests/PaneGeometryTests.swift) verifies stable pane identities and exact frames through horizontal and nested vertical splits. Unaffected branches keep their frames, and closing restores the previous geometry.

## Pane geometry bounds

[PaneGeometryTests.swift](../../Tests/BrowseCoreTests/PaneGeometryTests.swift) verifies that small viewports grow to fit minimum pane sizes, divider gaps remain consistent, and drag fractions respect both branches' bounds.

## Divider pointer tracking

[PaneResizingTests.swift](../../Tests/BrowseTests/PaneResizingTests.swift) sends real window mouse events through horizontal and vertical dividers in an offscreen browser layout.

Clicking and releasing a divider without moving must leave automatic-sizing intent unchanged.

Native hit testing must reach each divider, whose cursor-update tracking selects the appropriate horizontal or vertical resize cursor. Repeated pointer coordinates, forward movement, reversals, and release preserve the expected pane size without feedback from the divider’s changing position. Axis cases run sequentially because they share native mouse-gesture state.

## Divider bounds

Divider updates clamp fractions to safe bounds and leave unrelated split nodes unchanged, preventing extreme drag values from making persisted panes disappear.

## Clipped resize cursors

[[Tests/BrowseTests/PaneResizingTests.swift#clippedResizeCursors]] exercises pane and sidebar resize handles outside a clip view, then visible, hidden, empty, and detached, ensuring invalid cursor rectangles never reach AppKit.

The fully clipped case has a null intersection with an infinite origin, matching the cursor-registration crash. Visible handles still register their resize regions.
