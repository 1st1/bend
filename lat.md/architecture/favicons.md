# Favicons

Page icon discovery, persistent caching, and sidebar presentation.

See [[lat.md/tests/favicons-tests|Test coverage]].

## Persistent favicon cache

[[Sources/Browse/FaviconCache.swift#FaviconCache]] keeps a bounded profile cache of successful website icons so restored tabs display their favicons before their pages are loaded.

Regular windows share [[Sources/Browse/BrowserStore.swift#BrowserStore#faviconCache]] through the root store. The cache stores at most 256 recently refreshed HTTP(S) origins in Favicons.json beside the profile session. Keys include scheme, hostname, and effective port, with no credentials, paths, queries, or fragments. Each image is rasterized to a bounded 64-pixel sRGB PNG; reads validate image size and format, and reject oversized, malformed, or unsupported snapshots. Writes are debounced and atomic, with a final flush during session saving. Cache failures preserve in-memory icons and do not block browsing. Clearing regular browsing history clears the persistent icon cache too.

[[Sources/Browse/BrowserStore.swift#BrowserStore#favicon]] reads existing controllers or cached icons without creating WebViews. [[Sources/Browse/BrowserStore.swift#PageController#discardFavicon]] seeds a live pane only from its destination origin. [[Sources/Browse/BrowserStore.swift#PageController#refreshFavicon]] refreshes and records successful results through the existing document-scoped WebKit loader, preserving its network and cancellation rules. Shared-cache notifications update mounted rows in other regular windows.

Private stores do not create, read, or write this cache. Their icons remain in their individual live pane controllers, without sharing regular or other private panes' icon state. [[lat.md/tests/favicons-tests#Persistent favicon restoration]] covers unloaded tabs, live refresh, profile/window ownership, clearing, and private exclusion; [[lat.md/tests/favicons-tests#Favicon cache bounds and recovery]] covers normalization, bounds, and disposable-file recovery.

## Page favicons

[FaviconLoader](../../Sources/Browse/FaviconLoader.swift) loads icons inside the originating WebKit document so favicon requests obey its security policy and only a small raster image reaches the native UI.

[FaviconLoader.candidates](../../Sources/Browse/FaviconLoader.swift) discovers standard icons before touch icons and appends the origin's favicon fallback. Candidate count and URL length are bounded. Internal and local documents do not request favicons.

[FaviconLoader.imageScript](../../Sources/Browse/FaviconLoader.swift) loads anonymous-CORS images in an isolated script world. The originating document's image CSP, mixed-content rules, redirect checks, and WebKit content blocking apply; there is no native networking fallback. Cross-origin icons without CORS permission fall back to another candidate or the site initial. Requests omit the referrer; normal WebKit image credential rules apply.

[PageController](../../Sources/Browse/BrowserStore.swift) associates the displayed icon with the page origin that produced it. Links, reloads, and address entry within the same HTTP(S) origin keep that icon while the new document loads and refreshes it. A failed or policy-blocked refresh keeps the last successful same-origin icon. Scheme, hostname, or effective port changes, including redirects, clear it; internal and local pages also clear it. Late results from cancelled or replaced documents cannot restore an old icon. [[lat.md/tests/favicons-tests#Favicon navigation reset]] covers continuity and origin changes.

[[Sources/Browse/BrowserStore.swift#PageController#refreshFavicon]] retries an interrupted icon load when same-origin History API navigation changes its URL. Client-side navigation has no new navigation-finished callback, so discarding the old result without retrying would leave the sidebar and media card on fallback icons. [[lat.md/tests/favicons-tests#Favicon history navigation]] covers this race during playback.

[[Sources/Browse/SidebarTabIcon.swift#SidebarTabIcon#updateNSView]] displays the focused pane's favicon beside the tab title. Multi-pane tabs stack exactly two icons: the focused pane in front and the first other pane in layout order centered behind it, shifted upward and dimmed to 65% opacity. A subtle clipped contact-shadow gradient darkens the rear icon toward the front image’s overlapping edge, making the depth visible at small sizes. [[Sources/Browse/SidebarTabIcon.swift#SidebarTabIconView#updateStack]] fades changed stack positions in over 120 ms when focus switches or a pane joins the stack. Initial mounting and unrelated updates do not animate; Reduce Motion disables the fade. The pane count appears after the tab title in small muted text when the sidebar is at least 160 points wide. Single-pane tabs hide the rear icon and count. Favicon and focus changes update the mounted icon without instantiating an unvisited tab's WebView. Missing icons use a globe; native Bend pages use their own symbols. [[Sources/Browse/SidebarTabIcon.swift#SidebarTabIconView#layout]] keeps the front image at sixteen points and the rear image at twelve points vertically centered together within a fixed twenty-four-by-twenty-eight-point slot, clipping oversized rasters and leaving row text aligned. Sidebar favicons, including single-pane tabs, and pane-title favicons clip to [[Sources/Browse/BrowserView.swift#Chrome#faviconCornerRadius|a two-point corner radius]]. The decoration does not intercept tab clicks or drags, and the tab button exposes its pane count to accessibility. [[lat.md/tests/favicons-tests#Sidebar favicons]] covers live focus/icon/count updates and lazy-tab preservation.

Each image attempt times out. Oversized image dimensions are rejected, and successful images are rasterized to a small PNG before leaving WebKit. [FaviconLoader.load](../../Sources/Browse/FaviconLoader.swift) bounds that result and discards it on cancellation or URL changes. [[lat.md/tests/favicons-tests#Favicon request security]] verifies CSP, redirects, CORS, and isolation from page-owned JavaScript prototypes.
