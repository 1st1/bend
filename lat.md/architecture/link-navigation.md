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

[[Sources/Browse/BrowserStore.swift#BrowserStore#openLink]] shares destination handling with modified clicks. New panes open beside the source without claiming its dedicated Command-click pane; new tabs insert below the active sidebar row and load in the background without changing the selected tab, pane focus, or zoom. Modified clicks and explicit context-menu destinations open tabs in the background. Ordinary new-window links (such as an unmodified click on a `target="_blank"` link) select the new tab. Explicit new-tab commands still select the new tab. Main-frame links retain opener metadata, while iframe links omit it. New windows use the owning store's window callback. Explicit menu destinations ignore click preferences and leave the source page unchanged. [[lat.md/tests/link-navigation-tests#Link context menu destinations]] exercises actual WebKit hit tests and native menu actions.

## Link hover preview

Hovering a link shows its destination in a compact, noninteractive bubble at the bottom of that browser pane. Hovering the title drag handle uses the same bubble for the current page URL.

[LinkHoverPreview.swift](../../Sources/Browse/LinkHoverPreview.swift) observes link targets in an isolated WebKit content world, including subframes and nested elements in open shadow roots. Relative destinations resolve against the document base URL. Encoded URLs retain their full scheme, with control and directional formatting characters removed; long destinations truncate in the middle only when available space requires it. [[Sources/Browse/LinkHoverPreview.swift#LinkHoverPreview#place]] uses the text cell’s fitting size, including internal layout padding, rounded up before limiting it to the pane. Measuring the string or drawing rectangle alone can trigger truncation even when the URL has room.

[WebSurfaceHost.swift](../../Sources/Browse/WebSurfaceHost.swift) places the preview above page content without intercepting clicks. It prefers the bottom-left corner, switches to the right when the cursor approaches, and returns left once clear. Native pointer tracking updates placement even within the same link; layout also recomputes it after resizing. When a long URL would overlap the cursor at both corners, it truncates into the roomier side with a gap around the pointer. Leaving the pane, hiding it, scrolling, clicking, or navigating clears the preview. [FocusWebView](../../Sources/Browse/BrowserStore.swift) clears hover state when reattached, preserving pane-local behavior across live transfers. Shared content controllers route hover messages to their originating web view rather than retaining a pane or page controller. [[Sources/Browse/PaneDragging.swift#PaneDragSourceView]] gives the title URL priority over delayed DOM link events while the pointer remains above page content through [[Sources/Browse/WebSurfaceHost.swift#WebSurfaceHost#showTitlePreview]]. Leaving, pressing, hiding, or removing the title handle clears its preview. Navigation and web-view reattachment clear both URL sources. Title and link URLs share [[Sources/Browse/LinkHoverPreview.swift#LinkHoverObserver#displayURL|display sanitization]]. [[lat.md/tests/link-navigation-tests#Title URL preview]] covers the native hover lifecycle.

## Return to origin tab

Link-created tabs remember their source tab so closing the selected child returns to its origin when that tab is still open in the same window.

[[Sources/BrowseCore/Session.swift#BrowserTab#originTabID]] persists this relationship independently of WebKit opener metadata, including iframe links. [[Sources/Browse/BrowserStore.swift#BrowserStore#newTab]] records the source tab for link callbacks and explicit destinations. [[Sources/Browse/BrowserStore.swift#BrowserStore#closeTab]] prefers the surviving origin across workspaces, otherwise retaining the existing neighboring-tab fallback. Closing background tabs does not change selection. Nested links return one level at a time.

## Back from a link-created tab

Back navigates existing page history first; at its beginning, it closes an unpinned single-pane link-created tab and returns to its origin when available.

[[Sources/Browse/BrowserStore.swift#BrowserStore#goBack]] shares this behavior between the pane Back button and the Back menu/Command-[ shortcut. It uses persisted origin metadata, so manually created tabs do not close. Splitting a link-created tab prevents tab closure; its original link-opened pane can instead close under the pane preference, preserving the remaining panes. Pinned tabs remain open, and ordinary history navigation still works. Closing uses the normal reopen stack and origin/neighbor fallback. Link-created controllers first load an inert, per-controller `bend://close/<token>` document served by [[Sources/Browse/CloseHistoryPage.swift#CloseHistoryPage]], then the requested destination. This gives WebKit a real Back item, so its native gestures own recognition, cancellation, scrolling, and animation without custom swipe recognition or distance thresholds. The navigation delegate rejects that exact marker synchronously in WebKit's early history-traversal policy, before cached-page restoration or normal loading, then closes only an eligible tab or pane in the active tab. Ordinary navigation policy retains the marker guard as a fallback. Ordinary URL loads cannot trigger closure. Disabled or pinned targets reject marker navigation. [[Sources/Browse/HistorySwipeGuard.swift#HistorySwipeGuard]] observes native scroll events and disables WebKit navigation gestures before the first backward delta toward an unavailable marker. This prevents the marker preview and its three-second cleanup timeout. Every event reaches WebKit unchanged; zero-delta starts and forward gestures remain native. Suppression lasts through release and momentum, with eligibility reevaluated on the next gesture and real navigation restoring snapshot recording. The marker never replaces the last real URL in session state, visits, or the reopen stack. Replacement WebViews and restored link tabs seed a fresh marker before loading their first document.

[[Sources/Browse/BrowserStore.swift#BrowserStore#closeLinkTabOnBack]] is enabled by default, including older sessions with no stored value. Settings → Navigation → Back Navigation exposes the toggle, persisted in the root session and applied live across windows. [[lat.md/tests/link-navigation-tests#Back closes link-created tabs]] covers history traversal and eligibility.

## Back from a link-created pane

Link-opened panes use native Back history to close at their first page, with a separate default-on preference. Manual splits remain open.

[[Sources/Browse/BrowserStore.swift#BrowserStore#openPane]] records the source in [[Sources/BrowseCore/Session.swift#Page]] before the new pane loads, including links originating in frames and newly created dedicated panes. [[Sources/Browse/BrowserStore.swift#BrowserStore#newTab]] also records the source pane on the initial page of link-opened tabs, so adding panes does not lose that page's eligibility. Reused dedicated panes retain their existing history and origin. The private history marker described above lets WebKit own swipe recognition and animation. [[Sources/Browse/BrowserStore.swift#BrowserStore#goBack]] traverses real history first, then closes eligible panes through the normal reopen stack and focuses the surviving origin when available. Pinned panes, pinned tabs, and sole remaining panes are protected from pane closure. The separate tab rule still applies when eligible.

[[Sources/Browse/BrowserStore.swift#BrowserStore#closeLinkPaneOnBack]] defaults to enabled for older sessions and is shared across windows, persisted independently of the tab toggle. Settings → Navigation → Back Navigation exposes it. Pane origins survive session restoration and reopening. [[lat.md/tests/link-navigation-tests#Back closes link-created panes]] covers native history and the preference.
