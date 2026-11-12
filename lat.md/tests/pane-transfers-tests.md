---
lat:
  require-code-mention: true
---
# Pane transfers tests

Tests verify pane and tab drag operations within and between browser windows.

See [[lat.md/architecture/pane-transfers|Architecture and behavior]].

## Pane drop layout moves

[PaneDropTests.swift](../../Tests/BrowseCoreTests/PaneDropTests.swift) checks every source, target, and edge combination in a nested layout, preserving all pane IDs and unrelated split fractions while rejecting missing or identical endpoints.

## Cross-tab pane transfer model

[PaneTransferTests.swift](../../Tests/BrowseCoreTests/PaneTransferTests.swift) checks transfers at all four edges across workspaces, source collapse, empty-workspace recovery, detaching, invalid moves, and valid session restoration.

Moving a designated Command-click pane clears the source tab’s designation and does not claim an ordinary pane in the destination.

## Cross-tab native pane dragging

[PaneTransferTests.swift](../../Tests/BrowseTests/PaneTransferTests.swift) drives a single-pane tab through sidebar hover into an unvisited tab, drops on its WebKit content, then detaches into sidebar space.

Both sidebar positions exercise native sidebar drop targets, including returning a pane to unused sidebar space.

The test uses the unified titlebar and glass window hierarchy. It verifies delayed-hover cancellation, destination selection, source-tab removal, edge placement, direct row drops before the hover delay, zoomed-pane detaching and row drops, self-row rejection, and saved layouts. Consecutive same-tab drops alternate between panes during hover animation and after focus/layout updates in a key window, and every release must reach the window drag controller. The same live web view, document timestamp, unsaved input, and extension tab adapter survive transfers without creating closed-item history. A missing mouse-up is followed by a press on another pane, which must cancel stale tracking and complete a fresh drag. A whole-tab row-center drop preserves the source split tree, live document timestamp, unsaved input, controller, and extension adapter inside the joined destination. All data and HTTP pages are disposable.

## Pane drop targeting

[PaneDropTests.swift](../../Tests/BrowseCoreTests/PaneDropTests.swift) verifies normalized edge selection, half-pane preview frames, and rejection of outside points or empty viewports.

## Pane drop validation and persistence

[PaneDropTests.swift](../../Tests/BrowseTests/PaneDropTests.swift) checks hidden, zoomed, stale-pane, and missing-source-tab rejection. A valid move preserves URLs, focuses the moved pane, survives session restoration, and creates no closed-item history.

## Native pane drop lifecycle

[PaneDropTests.swift](../../Tests/BrowseTests/PaneDropTests.swift) sends mouse events through an ordered offscreen window to verify preview updates, cancellation without mutation, outside rejection, surface cleanup, and a valid move on release.

The native preview layer is observed during continuous movement and edge changes. It must never transition to hidden while the pointer remains over a valid pane, including between events and layout passes. The drag surface must never intercept hit testing; SwiftUI representable teardown clears the overlay, preview, and tracking before native view removal, and a subsequent drag still works. Teardown and window deactivation leave the window consuming the cancelled gesture until release, then return it to idle.

## Pane header mouse routing

[PaneDropTests.swift](../../Tests/BrowseTests/PaneDropTests.swift) sends window mouse events through the actual browser shell, unified titlebar, and glass container in an ordered offscreen window.

Ordinary header hit testing reaches the compact title handles, which drive hover feedback and pane dragging. During a title press, native dispatch instead uses the window-owned mouse target, which accepts first mouse and remains mounted through release. All three mouse event types must pass through AppKit. Mouse-down focuses the pane; small motion does not move the window or begin a drag, and mouse-up clears tracking. Empty header and sidebar backgrounds request native window dragging. Tab rows, toolbar controls, sidebar resize handles, and traffic lights are excluded; native clicks still activate the sidebar toggle without creating a tab.

Background drag gestures cross the native titlebar drag threshold before asserting the request: AppKit can defer the initial mouse-down. Every background window-drag request must originate inside AppKit's normal event dispatch, so activating clicks cannot skip native window appearance bookkeeping. Outside mouse-down dispatch the background targets do not claim hit testing, preserving underlying scroll and hover behavior.

## Pane transfer round trips

[PaneTransferTests.swift](../../Tests/BrowseTests/PaneTransferTests.swift) moves the same live pane between two surviving tabs 24 times per layout, using normal and scrolling layouts to check the third drag and later round trips.

The first twenty transfers in each layout hover to select the destination before dropping onto a pane; the remainder drop directly onto the tab row. Each press must reach exactly one visible handle with current tab ownership. AppKit must receive every mouse event through the same window-owned target across transfers, and the window must return to idle after release. Synthetic window events verify retained page controllers, document tokens, unsaved form contents, and unique model ownership while both tab trees remain mounted. Document tokens are injected after navigation and must survive every move; wall-clock-derived performance timestamps are not identity checks.

## Joining tab layouts

[PaneTransferTests.swift](../../Tests/BrowseCoreTests/PaneTransferTests.swift) verifies joins preserve both split trees, page identities, destination title, and source focus, remove the source tab, and survive serialization.

Same-workspace and cross-workspace joins retain valid sessions, including replacement of an emptied workspace. Self-joins and missing endpoints leave the session unchanged. A join retains the destination’s dedicated Command-click pane when present, otherwise adopts the source’s; that designation also survives serialization.

## Tab merge placement

[PaneTransferTests.swift](../../Tests/BrowseCoreTests/PaneTransferTests.swift) checks all four merge edges, intact source trees, untouched destination branches and fractions, focus, title, persistence, and atomic rejection of stale or foreign target panes.

## Tab drag hover and merge placement

[PaneTransferTests.swift](../../Tests/BrowseTests/PaneTransferTests.swift) drives native tab drags through delayed selection and all four pane-edge merges, checking timer cancellation, zoom exit, preview cleanup, and preservation of live page and extension identities.

## Cross-window live transfers

[CrossWindowDragTests.swift](../../Tests/BrowseTests/CrossWindowDragTests.swift) verifies whole-tab and repeated pane transfers preserve live documents, form edits, both zoom modes, controller ownership, callbacks, and extension adapters.

Invalid source or destination IDs leave models untouched. Both sessions remain valid, a source with remaining tabs stays open, moves add no closed-history items, saved layouts reflect the transfer, and closing the source does not stop transferred pages.

## Cross-window drag gestures

[CrossWindowDragTests.swift](../../Tests/BrowseTests/CrossWindowDragTests.swift) drives native pane gestures and sidebar tab handles between two mounted browser windows, checking destination previews, cancellation, insertion, and WebView attachment.

The pressed window receives pointer coordinates even over another window. Pane and sidebar previews raise the destination above other browser windows while preserving the key window and active drag. Cancelled drags clear the remote overlay and leave ownership unchanged; successful moves clean up tracking and mount the original WebView in its destination.

## Empty window transfer cleanup

[CrossWindowDragTests.swift](../../Tests/BrowseTests/CrossWindowDragTests.swift) verifies moving the final tab or pane closes only the source window, preserves the live destination document and extension adapter, and removes the source from restoration.

Invalid drops leave both windows open. The surviving window retains unsaved form contents, no closed-history entry is created by the transfer, and reopening restores only the destination window and its transferred page.

## Detached window ownership

[[Tests/BrowseTests/DetachedWindowTests.swift#DetachedWindowTests#detachedWindowOwnership]] verifies pane and whole-tab detachment preserves live WebViews, form state, page zoom, pins, and saved window membership without an extra blank tab or closed history.

Whole-tab detachment preserves split layout, tab identity, and the dedicated-link pane. Exhausted source windows close after transfer, while a source with remaining panes stays open. Invalid sources create no window, and destination frames fit the chosen display.

## Outside-window drag gestures

[[Tests/BrowseTests/DetachedWindowTests.swift#DetachedWindowTests#outsideWindowDragGestures]] drives native pane and tab gestures through the threshold, outside preview, return, cancellation, and successful release into a new window.

The preview remains mouse-transparent and nonactivating, grows outside, shrinks on return, and does not mask the source window as a drop target. Near-edge size hysteresis leaves exact outside-drop eligibility unchanged. No destination exists before release; cancellation clears the panel and retains ownership. Both final drop paths leave no preview or extra blank tab. `BEND_DRAG_PREVIEW_SNAPSHOT` optionally captures the expanded card for visual review.

Tab drags retain a compact title badge inside their source window, show the thumbnail after leaving, and restore the badge on return; repeated boundary crossings do not leave both visuals visible.

## Drag preview motion

[[Tests/BrowseTests/DetachedWindowTests.swift#dragPreviewMotion]] moves the preview continuously while it grows and shrinks, verifying its cursor anchor never trails the latest pointer or jumps back to an earlier position.

After motion stops, the size transition must finish at the requested dimensions without moving the cursor anchor. Landscape and portrait sources retain their thumbnail aspect ratio without extra space in compact, expanded, and intermediate sizes; both outer dimensions remain within the 250-point cap. This regresses competing panel-position and resize animations.

## Drag preview rendered proportions

[[Tests/BrowseTests/DetachedWindowTests.swift#dragPreviewRenderedProportions]] renders wide, tall, and shallow pane previews, checking that captured squares stay square and web content reaches the thumbnail edges after capped resizing.

A web-only snapshot occupies its original content rectangle inside the miniature pane, retaining header geometry. Long titles must truncate rather than widen portrait cards. Compact, expanded, and restored compact renders preserve proportions within native pixel rounding without letterboxing; shallow panes retain their captured height rather than layout minimums.

## Drag preview glass isolation

Drag thumbnails must not bitmap-render a live pane or disturb its native glass, page state, or viewport.

[[Tests/BrowseTests/DetachedWindowTests.swift#dragPreviewGlassIsolation]] mounts a real web surface with glass, waits for a WebKit thumbnail, and rejects native pane captures. The visible snapshot excludes the header; showing and cancelling the preview preserves the header instance and frame, WebView ownership and geometry, content inset, and document state.
