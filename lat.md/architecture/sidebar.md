# Sidebar

Sidebar placement, sizing, floating presentation, and tab ordering.

See [[lat.md/tests/sidebar-tests|Test coverage]].

## Sidebar placement

The Sidebar position picker in General settings docks the sidebar on either side. Left is the default for existing and new profiles; the saved preference applies to all regular and private windows.

[[Sources/Browse/BrowserStore.swift#BrowserStore#sidebarSide]] shares the optional [[Sources/BrowseCore/Session.swift#BrowserSession#sidebarSide]] preference through the root store. [[Sources/Browse/BrowserView.swift#BrowserView]] retains the mounted canvas while moving the sidebar, mirrors its inner and outer margins, resize edge, transition, and media-card margin, and keeps native traffic lights at the upper-left with space in the first visible pane header. Hidden-sidebar controls remain beside those lights. Floating reveal follows the selected edge; changing sides dismisses a floating panel.

## Sidebar sizing

[SidebarResizing.swift](../../Sources/Browse/SidebarResizing.swift) supplies an invisible eight-point handle at the sidebar's canvas-facing edge, with a horizontal resize cursor and immediate resizing between 200 and 400 points.

Dragging the canvas-facing edge uses mirrored directions and measures pointer movement in window coordinates so resizing the sidebar cannot feed movement back into the gesture. [BrowserStore.swift](../../Sources/Browse/BrowserStore.swift) clamps and saves the width in the session. Missing or nonfinite widths default to 250 points; saved widths inside the range remain unchanged and out-of-range values are clamped. Hiding the sidebar preserves its width, and resizing retains live pane controllers. [[Sources/Browse/SidebarResizing.swift#SidebarResizeView#resetCursorRects]] skips detached, hidden, empty, and nonfinite cursor regions, as verified by [[lat.md/tests/pane-layout-tests#Clipped resize cursors]].

[BrowserView.swift](../../Sources/Browse/BrowserView.swift) animates collapse and restoration over 200 ms with an ease-in-out curve. The sidebar slides and fades at its configured edge while the native pane canvas resizes in place, retaining its WebViews and document state. Rapid toggles reverse toward the latest layout. Reduce Motion disables the animation; width dragging remains immediate. [[lat.md/tests/sidebar-tests#Sidebar visibility animation]] covers intermediate geometry, stable native parents, retained form state, and reversal.

## Floating sidebar

[FloatingSidebar.swift](../../Sources/Browse/FloatingSidebar.swift) reveals the hidden sidebar at the configured window edge without resizing the browser canvas or changing the pinned-sidebar preference.

In the key window, moving within thirteen points of the configured edge reveals a rounded panel using the saved sidebar width and window material. It extends to a six-point top inset in both windowed and fullscreen modes, covering the browser pane and its titlebar beneath the native traffic lights. Its compact header reserves traffic-light space when on the left and aligns its pin and download controls with their centerline. The panel slides and fades in from its configured edge over 180 ms; Reduce Motion makes the transition immediate. The existing tab list supports selection, closing, and new tabs; its sidebar toggle pins it open. Hovering the panel or its small edge gap keeps it visible. Leaving for 180 ms dismisses it; reentry cancels dismissal. Window deactivation also dismisses it. Hover state is transient and independent per window.

[BrowserView.swift](../../Sources/Browse/BrowserView.swift) overlays the panel above the unchanged mounted canvas. [BrowseWindow.swift](../../Sources/Browse/BrowseWindow.swift) routes panel presses directly to AppKit so underlying pane and window drag regions cannot capture them. [[lat.md/tests/sidebar-tests#Floating sidebar interaction]] covers native hit testing, selection, hover lifetime, and preserved canvas geometry.

## Sidebar overflow indicators

[[Sources/Browse/SidebarScrollStatus.swift#SidebarScrollStatus]] counts tabs fully outside the visible scroll viewport. Small pills show those counts at the top and bottom fades in docked and floating sidebars.

Partially visible rows are excluded. Zero counts hide their pill; an empty list or unmeasured viewport hides both. Counts follow scrolling, resizing, tab membership, and the content inset beneath favorites. The calculation shares [[Sources/Browse/BrowserView.swift#Chrome#sidebarTabHeight]] and [[Sources/Browse/BrowserView.swift#Chrome#sidebarTabSpacing]] with the fixed-height row layout.

[[Sources/Browse/SidebarScrollStatus.swift#SidebarOverflowPill]] overlays a compact material capsule outside the content opacity mask, without reserving space or intercepting scrolling, selection, or dragging. Pills use 9-point text and a borderless material background at 80% opacity, with no directional icon. Their position identifies the edge; accessibility labels name both the count and edge. [[lat.md/tests/sidebar-tests#Sidebar overflow counts]] covers edge positions, partial visibility, favorites, and changing viewport or tab counts.

## Sidebar tab reordering

[TabReordering.swift](../../Sources/Browse/TabReordering.swift) uses native sidebar drags to reorder or join tabs, with distinct insertion-line and whole-row previews.

A native mouse handle covers the tab label and starts dragging after five points of movement; ordinary clicks still select the tab, and close controls remain separate. Inside the source window, a compact title badge follows the pointer and changes to “Join tabs” over join targets, while a window-level surface draws insertion lines using the sidebar rows’ actual bounds. Leaving the source window shows the floating [[lat.md/architecture/pane-transfers#Dragging into a new window|thumbnail card]]; returning immediately hides it and restores the badge. The middle 60% of a visible row joins tabs and shows a whole-row highlight. The top and bottom 20% select reorder boundaries; blank sidebar space after the last row remains an end-of-list target. Escape, window deactivation, source removal, or an invalid in-window release cancels without merging or changing order. Releasing outside Bend windows creates a new window. The drag surface ignores hit testing, and retiring a SwiftUI handle explicitly clears its tracking and overlay. A fresh mouse-down cancels any unfinished gesture before reaching the newly clicked control. The event monitor forwards mouse-up to AppKit so repeated drags work. A completed move animates for 180 ms unless Reduce Motion is enabled.

Hovering a row’s join area for 400 ms selects the destination tab and clears zoom, retaining the original dragged tab. Moving into its visible canvas previews a merge above, below, left, or right of a chosen pane, using the same half-pane geometry as pane dragging. The whole source split tree occupies that half. Leaving the row cancels its pending timer; leaving a pane clears its preview. Cancellation after preview leaves the destination selected, matching pane dragging. Already-visible destination panes can be targeted directly; hidden panes, source-tab panes, zoomed canvas targets, stale sources, and unrelated windows are rejected.

[BrowserStore.swift](../../Sources/Browse/BrowserStore.swift) changes only the tab array for reordering and saves its order. Reordering leaves selection, pane layouts, zoom, live page controllers, and closed-item history unchanged. Self-drops, missing tabs, and already-adjacent placements are no-ops. Targets in another Bend window use [[lat.md/architecture/pane-transfers#Cross-window dragging]]; external pasteboard drags cannot reorder tabs. Joining removes the source tab and preserves its entire split tree. A direct sidebar drop places it to the right of the destination tree; a canvas drop replaces only the chosen destination leaf with an equal split along the selected edge, preserving unrelated branches and fractions. Internal split identities and fractions, page IDs, live controllers, and extension identities survive. The destination tab keeps its title, becomes selected, focuses the source’s focused pane, and exits zoom. No closed-item history is created; the combined layout is saved atomically. [[lat.md/tests/pane-transfers-tests#Joining tab layouts]] covers model invariants and restoration. [[lat.md/architecture/pane-transfers#Pane drag and drop|Pane transfers]] use separate tracking and targets.

## Sidebar materials

The sidebar and exposed workspace share one native Liquid Glass base. Selected tabs use capsule-shaped glass; selected favorites share that material and corner radius.

Legacy standard-material fallbacks remain in the source but are outside the supported OS range.

[BrowserWindows.swift](../../Sources/Browse/BrowserWindows.swift) hosts each SwiftUI workspace inside [BrowserWindowGlass](../../Sources/Browse/GlassAppearance.swift), which observes the persisted window style and tint without replacing its content view. AppKit manages the glass/content geometry together; the transparent window supplies the outer corner clipping. The base spans the sidebar, titlebar area, and gaps around panes, including when the sidebar is hidden. A separate background scrim controls its darkening without dimming foreground content.

[BrowserView.swift](../../Sources/Browse/BrowserView.swift) omits the legacy sidebar and canvas backdrops on macOS 26 and later so they do not cover the shared glass. Legacy behind-window sidebar and under-window material paths are outside the supported OS range. Selection has no custom fill or border, and pane chrome retains its separate darkened material. Inactive tab hover adds a capsule filled with the shared 6% white button highlight and reveals a close button. Unselected, unhovered tabs omit the close button and reclaim its width and spacing for the title. Hovering or selecting a tab shortens the title to make room for close; leaving an unselected tab restores the extra title space. Titles that exceed their available width fade to transparent over the trailing 24 points instead of showing an ellipsis; fitting titles remain fully visible. Hover fades over 100 ms, or changes immediately with Reduce Motion; selected tabs retain their glass selection.
