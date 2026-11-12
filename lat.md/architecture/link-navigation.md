# Link navigation

Modified clicks, link context menus, and destination previews.

See [[lat.md/tests/link-navigation-tests|Test coverage]].

## Option-click event routing

[[Sources/Browse/OptionClickObserver.swift#OptionClickObserver]] captures trusted Option-left-clicks on HTTP(S) links in an isolated content world, cancelling WebKit's default before it can bypass navigation policy on macOS 26.

The document-start script runs in all frames, follows composed event paths for nested links, and respects page cancellation and Command/Control modifiers. Page-generated events and unsupported schemes are ignored. A native handshake enables interception only in routed panes, so other WebViews sharing an extension content controller keep their default behavior. The message handler validates the destination and uses WebKit's originating view and frame metadata, then invokes the pane's live Option-click preference. Replacement views reinstall routing; native navigation-policy handling remains a fallback.

[[lat.md/tests/link-navigation-tests#Native Option-click links]] verifies real native events use the bridge without source navigation or downloads. [[lat.md/tests/link-navigation-tests#Option-click shared controller isolation]] checks that shared script installation cannot route another view's links.

## Link context menus

[[Sources/Browse/LinkContextMenu.swift#PageController#contextMenu]] adds explicit new-tab, new-pane, and new-window actions, in that order, to HTTP(S) link menus while retaining WebKit's other actions.

[[Sources/WebKitFindSupport/BendContextMenuDelegate.m]] obtains the clicked URL and source frame through WebKit's macOS context-menu SPI, including iframe links. Checked selectors leave the native menu intact when hit-test support is unavailable, the element cannot be followed, or the URL is not HTTP(S). Each menu item retains its own target; hover state is not used. The native Open Link in New Window item is replaced to avoid duplicate or misleading actions. Copy Link, Download, inspection, and extension items remain available.

[[Sources/Browse/BrowserStore.swift#BrowserStore#openLink]] shares destination handling with modified clicks. New panes open beside the source without claiming its dedicated Command-click pane; new tabs insert below the active sidebar row and load in the background without changing the selected tab, pane focus, or zoom. Modified-click destinations retain their existing foreground behavior. Main-frame links retain opener metadata, while iframe links omit it. New windows use the owning store's window callback. Explicit menu destinations ignore click preferences and leave the source page unchanged. [[lat.md/tests/link-navigation-tests#Link context menu destinations]] exercises actual WebKit hit tests and native menu actions.

## Link hover preview

Hovering a link shows its destination in a compact, noninteractive bubble at the bottom of that browser pane. Hovering the title drag handle uses the same bubble for the current page URL.

[LinkHoverPreview.swift](../../Sources/Browse/LinkHoverPreview.swift) observes link targets in an isolated WebKit content world, including subframes and nested elements in open shadow roots. Relative destinations resolve against the document base URL. Encoded URLs retain their full scheme, with control and directional formatting characters removed; long destinations truncate in the middle only when available space requires it. [[Sources/Browse/LinkHoverPreview.swift#LinkHoverPreview#place]] uses the text cell’s fitting size, including internal layout padding, rounded up before limiting it to the pane. Measuring the string or drawing rectangle alone can trigger truncation even when the URL has room.

[WebSurfaceHost.swift](../../Sources/Browse/WebSurfaceHost.swift) places the preview above page content without intercepting clicks. It prefers the bottom-left corner, switches to the right when the cursor approaches, and returns left once clear. Native pointer tracking updates placement even within the same link; layout also recomputes it after resizing. When a long URL would overlap the cursor at both corners, it truncates into the roomier side with a gap around the pointer. Leaving the pane, hiding it, scrolling, clicking, or navigating clears the preview. [FocusWebView](../../Sources/Browse/BrowserStore.swift) clears hover state when reattached, preserving pane-local behavior across live transfers. Shared content controllers route hover messages to their originating web view rather than retaining a pane or page controller. [[Sources/Browse/PaneDragging.swift#PaneDragSourceView]] gives the title URL priority over delayed DOM link events while the pointer remains above page content through [[Sources/Browse/WebSurfaceHost.swift#WebSurfaceHost#showTitlePreview]]. Leaving, pressing, hiding, or removing the title handle clears its preview. Navigation and web-view reattachment clear both URL sources. Title and link URLs share [[Sources/Browse/LinkHoverPreview.swift#LinkHoverObserver#displayURL|display sanitization]]. [[lat.md/tests/link-navigation-tests#Title URL preview]] covers the native hover lifecycle.
