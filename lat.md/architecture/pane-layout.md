# Pane layout

Tiling geometry, automatic sizing, and layout animation.

See [[lat.md/tests/pane-layout-tests|Test coverage]].

## Tiling model

[Session.swift](../../Sources/BrowseCore/Session.swift) represents pane layouts as binary split trees. Splitting replaces the focused leaf; closing a leaf collapses its parent into the surviving sibling and repairs focus when necessary.

Splits carry an axis, fraction, and optional automatic-sizing intent. [[lat.md/architecture/pane-layout#Automatic pane sizing]] describes equal sizing and manual proportions. [BrowserView.swift](../../Sources/Browse/BrowserView.swift) draws draggable dividers, constrains pane minimum sizes, and scrolls oversized layouts. Zoom temporarily displays a single pane without modifying the saved split tree.

## Automatic pane sizing

Untouched rows and columns divide space equally when panes are opened, moved, joined, or removed. Manually resized layouts retain their proportions; new subdivisions can still distribute their own space automatically.

[[Sources/BrowseCore/Session.swift#PaneLayout#automaticUnits]] counts adjacent automatic splits along the same axis, treating perpendicular or manually sized subtrees as one unit. [[Sources/BrowseCore/PaneGeometry.swift#PaneGeometry#place]] allocates equal pane space after accounting for every divider gap, while preserving minimum sizes and scrollable overflow. The binary tree, pane order, identities, and insertion directions remain intact.

[[Sources/Browse/BrowserStore.swift#BrowserStore#resize]] passes current geometry to [[Sources/BrowseCore/Session.swift#PaneLayout#resizing]]. A manual resize freezes the layout's existing automatic dividers at their rendered fractions before changing the targeted divider, preventing other boundaries from jumping. Manual intent persists even when a divider returns to an equal fraction, and survives removal, transfers, and reopening. [[Sources/Browse/PaneResizing.swift#PaneDividerView#mouseDragged]] ignores clicks and constrained drags that do not change size.

[[Sources/BrowseCore/Session.swift#PaneLayout#usesAutomaticSizing]] treats older splits without sizing metadata as automatic only when their fraction is one-half; unequal legacy proportions remain fixed. Older data cannot distinguish an untouched half split from one manually returned to half. Newly resized splits save explicit manual intent.

## Pane layout animation

[PaneGeometry.swift](../../Sources/BrowseCore/PaneGeometry.swift) resolves the split tree into flat pane and divider frames. [BrowserView.swift](../../Sources/Browse/BrowserView.swift) keeps pane views keyed by page identity as their positions and sizes change.

Adding a pane animates existing frames over 180 ms with an ease-out curve. The new pane reveals horizontally for a right split or vertically for a lower split, without scaling its text or web content. The scroll view reveals the destination when it would extend beyond the viewport. Reduce Motion disables these layout and insertion animations.

The geometry retains pane minimum sizes and divider constraints, growing the scrollable canvas when necessary. [PaneResizing.swift](../../Sources/Browse/PaneResizing.swift) provides native divider views spanning the gaps, with AppKit cursor rectangles and cursor-update tracking for directional resize cursors. [[Sources/Browse/PaneResizing.swift#PaneDividerView#resetCursorRects]] skips detached, hidden, empty, and nonfinite regions: fully clipped intersections can have infinite origins that AppKit rejects. [[lat.md/tests/pane-layout-tests#Clipped resize cursors]] covers clipping and teardown. Dragging updates immediately using fixed window coordinates, so the moving divider does not feed its own movement back into the resize calculation. Tab switches and session restoration start at their final layout; animation state is not persisted.
