# Web pages

WebKit ownership, page printing, and JavaScript dialogs.

See [[lat.md/tests/web-pages-tests|Test coverage]].

## WebKit integration

[BrowserStore.swift](../../Sources/Browse/BrowserStore.swift) retains one WebKit controller per visited pane, keeping live pages and navigation history while switching tabs or changing layouts. The native host uses the system WebKit framework, not an embedded Safari application.

Selecting a visited tab does not load or reload its pages. Its [[lat.md/architecture/session#Mounted tab views|mounted view hierarchy]] stays attached while inactive. First visits, reopened closed pages, and process restarts still load URLs.

Website configurations append Safari-compatible product tokens and a Bend identifier to WebKit’s default user agent before navigation, including when leaving extension pages. The Safari version comes from the installed app’s bundle metadata, with a macOS 14-era fallback; this prevents sites such as Google from serving legacy fixed-width layouts. This does not read Safari preferences or share its session.

All panes share the app’s default persistent WebKit website data store, separate from Safari. Navigation updates the stored address and first-pane tab title. Command-clicking an HTTP or HTTPS link opens and focuses a new pane to the right of its source by default, or a new tab when selected in [[lat.md/architecture/settings#UI preferences]], leaving the source page unchanged and exiting pane zoom. This also applies to links targeting a new window; other new-window web links create tabs. [[Sources/Browse/BrowserStore.swift#BrowserStore#newTab]] inserts link-opened tabs immediately below the currently active tab in its workspace and selects them; manually created tabs retain their normal end placement. Errors offer retry, and page JavaScript alert, confirm, and text-input dialogs use the origin-labeled [[lat.md/architecture/web-pages#JavaScript dialogs|sheet coordinator]].

Command-click routing uses WebKit's navigation-action modifiers and left-button mask in both navigation policy and new-window callbacks. It cancels source navigation when opening the destination; plain clicks and non-link navigation retain their normal behavior.

Pane headers display [[lat.md/architecture/favicons#Page favicons|site favicons]] or a site initial when no usable icon is available. Internal pages retain their app symbols. Same-origin navigation keeps the last successful icon while refreshing it; leaving the origin clears it. Pending work is cancelled so stale results cannot replace the next page's icon.

Custom URL schemes use the confirmed [[lat.md/architecture/external-links#External application links|external-app handoff]]. Website files use [[lat.md/architecture/downloads#Browser downloads]]. Website media permissions, native Safari App Extensions, and Safari session sharing are outside the implemented prototype. Safari Web Extensions use the separate [[lat.md/architecture/extensions/lifecycle#Web extensions|Bend extension host]].

## Page printing

[[Sources/Browse/BrowseApp.swift#AppDelegate#printPage]] routes File → Print… and Command-P to WebKit's native print operation for the focused visible web page in the active browser window.

The standard macOS print sheet offers printer, page-layout, and PDF controls. It uses the page title for the job and leaves the live document intact on cancellation. Native Bend pages, failed or hidden pages, and unrelated utility windows cannot print. Existing sheets or print operations disable another request; completion releases the operation so printing can be opened again. [[lat.md/tests/web-pages-tests#Page printing]] exercises the shortcut, pane routing, native sheet, cancellation, and validation without submitting a print job.

## JavaScript dialogs

[JavaScriptDialogs](../../Sources/Browse/JavaScriptDialogs.swift) presents page-generated alerts, confirmations, and text prompts as native window sheets labeled with the initiating frame's security origin.

[PageController](../../Sources/Browse/BrowserStore.swift) forwards the originating WebKit frame rather than attributing subframe dialogs to the top-level page. Opaque origins receive an unknown-origin label; local files receive a local-file label. Page text and prompt defaults are bounded, and the native title always identifies JavaScript separately from untrusted message text.

[JavaScriptDialogs.request](../../Sources/Browse/JavaScriptDialogs.swift) admits only visible pages in a visible, non-minimized key window without another sheet. Requests are never queued. A window-wide rolling limit permits three dialogs per thirty seconds across all frames, panes, and navigations. A suppression checkbox blocks subsequent dialogs from that page until another navigation commits; navigation does not reset the window budget.

Navigation, web-view replacement, content-process termination, hiding or detaching a page, and closing or minimizing its window cancel pending dialogs. Late sheet callbacks cannot complete a request twice. Accepted responses are rechecked against the original view, window visibility, and URL. Rejected confirmations return false and rejected prompts return null; alerts always complete. [[lat.md/tests/web-pages-tests#JavaScript native sheets]] exercises a real AppKit sheet without an application-modal event loop.
