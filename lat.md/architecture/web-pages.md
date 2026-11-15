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

Custom URL schemes use the confirmed [[lat.md/architecture/external-links#External application links|external-app handoff]]. Website files use [[lat.md/architecture/downloads#Browser downloads]]. Website capture uses [[lat.md/architecture/web-pages#Website permissions]]. Native Safari App Extensions and Safari session sharing remain outside the implemented prototype. Safari Web Extensions use the separate [[lat.md/architecture/extensions/lifecycle#Web extensions|Bend extension host]].

## Page printing

[[Sources/Browse/BrowseApp.swift#AppDelegate#printPage]] routes File → Print… and Command-P to WebKit's native print operation for the focused visible web page in the active browser window.

The standard macOS print sheet offers printer, page-layout, and PDF controls. It uses the page title for the job and leaves the live document intact on cancellation. Native Bend pages, failed or hidden pages, and unrelated utility windows cannot print. Existing sheets or print operations disable another request; completion releases the operation so printing can be opened again. [[lat.md/tests/web-pages-tests#Page printing]] exercises the shortcut, pane routing, native sheet, cancellation, and validation without submitting a print job.

## JavaScript dialogs

[JavaScriptDialogs](../../Sources/Browse/JavaScriptDialogs.swift) presents page-generated alerts, confirmations, and text prompts as native window sheets labeled with the initiating frame's security origin.

[PageController](../../Sources/Browse/BrowserStore.swift) forwards the originating WebKit frame rather than attributing subframe dialogs to the top-level page. Opaque origins receive an unknown-origin label; local files receive a local-file label. Page text and prompt defaults are bounded, and the native title always identifies JavaScript separately from untrusted message text.

[JavaScriptDialogs.request](../../Sources/Browse/JavaScriptDialogs.swift) admits only visible pages in a visible, non-minimized key window without another sheet. Requests are never queued. A window-wide rolling limit permits three dialogs per thirty seconds across all frames, panes, and navigations. A suppression checkbox blocks subsequent dialogs from that page until another navigation commits; navigation does not reset the window budget.

Navigation, web-view replacement, content-process termination, hiding or detaching a page, and closing or minimizing its window cancel pending dialogs. Late sheet callbacks cannot complete a request twice. Accepted responses are rechecked against the original view, window visibility, and URL. Rejected confirmations return false and rejected prompts return null; alerts always complete. [[lat.md/tests/web-pages-tests#JavaScript native sheets]] exercises a real AppKit sheet without an application-modal event loop.

## Website file uploads

[[Sources/Browse/WebsiteFileUpload.swift#WebsiteFileUpload]] presents file and directory upload requests as native window sheets, with single or multiple selection according to WebKit’s parameters.

[[Sources/Browse/PagePermissions.swift]] supplies the WebKit open-panel delegate. Upload requests require a visible page in a key, visible, non-minimized window without an existing sheet. Concurrent requests fail closed. Navigation, hiding, replacement, process termination, and closure cancel the panel; late callbacks cannot complete twice or return files to another document. [[lat.md/tests/web-pages-tests#Website upload lifecycle]] covers these boundaries.

## Website permissions

[[Sources/Browse/PagePermissions.swift]] routes camera, microphone, and location requests through saved Ask, Allow, and Block choices.

[[Sources/BrowseCore/WebsitePermission.swift#WebsitePermission#origin]] distinguishes scheme, hostname, and effective port, unlike page zoom’s hostname matching. Both the requesting frame and top-level origin are checked; opaque and non-web origins are denied. Ask uses [[Sources/Browse/WebsitePermissionPrompt.swift#WebsitePermissionPrompt]] to show an origin-labeled sheet with a Remember my choice checkbox. Remembered choices apply to same-origin requests; embedded third-party requests still prompt and cannot save a grant through the sheet. Saved Allow bypasses the website prompt, but not macOS authorization. [[Sources/Browse/WebsitePermissionMenu.swift#WebsitePermissionMenu]] exposes Ask/Allow/Block and capture state in each page header, with camera/microphone stop controls. Newly blocked camera/microphone origins stop their active capture across subscribed panes. Closing a pane stops capture. Location blocks apply to subsequent requests; an existing watch requires reloading the page.

The settings store persists Allow and Block choices in regular windows and keeps private-window changes temporary. Settings → Websites uses [[Sources/Browse/WebsitePermissionsTable.swift#WebsitePermissionsTable|a searchable, scrollable table]] with one origin per row and camera, microphone, and location columns. Removing a row resets all its permissions to Ask in one saved update, preserving zoom and other origins; Ask removes the saved choice. Existing blocks survive the schema upgrade. macOS 27 uses the public geolocation selector; macOS 26 uses the equivalent WebKit SPI selector, isolated in [[Sources/Browse/PagePermissions.swift]]. Packaged location requests include a macOS usage description. [[lat.md/tests/web-pages-tests#Website permission isolation]] and [[lat.md/tests/settings-tests#Website permission persistence]] cover policy and persistence.

Permission sheets reject hidden/background pages and concurrent sheets; navigation, hiding, replacement, process termination, and closure cancel without saving. Late responses cannot complete twice. [[lat.md/tests/web-pages-tests#Remembered permission prompts]] covers explicit choices and cancellation.

Screen sharing retains WebKit’s native chooser. Camera and microphone indicators do not claim to represent screen capture; screen sharing is stopped through the website or macOS sharing controls. Website notifications and background push are not implemented; extension notifications remain separate.

## Browser passkeys

[[Sources/Browse/BrowserPasskeys.swift#BrowserPasskeys]] checks the running app’s signed browser-passkey entitlement before exposing Apple’s authorization request in Settings → Websites.

Unentitled builds omit the Passkeys section entirely and do not invoke the credential manager. An entitled build reports authorization and can request access; WebKit handles website challenges. Apple approval and matching provisioning are external prerequisites, described in [[docs/browser-capabilities.md]]. The default signature does not include the managed entitlement.

## Browser capability diagnostics

[[Sources/Browse/WebCapabilityProbe.swift#WebCapabilityProbe]] provides an isolated diagnostic window through the packaged app’s --diagnose-web-capabilities argument.

[[scripts/fixtures/browser-capabilities.html]] reports available web APIs and offers user-initiated camera, microphone, screen, location, notification, clipboard, fullscreen, and file-upload checks. It uses ephemeral storage and a synthetic HTTPS origin, with no automatic capture or media upload. This is a manual verification tool, not proof of live conferencing or background-push support. [[docs/browser-capabilities.md]] describes the checks and remaining integration prerequisites.

## Website certificates

[[Sources/Browse/WebsiteCertificates.swift#WebsiteCertificates]] displays the committed HTTPS page’s WebKit server trust in a native certificate sheet with trust editing disabled.

The site menu uses the shared toolbar button style and displays the committed site’s registrable domain, with the complete origin in its menu and tooltip. Certificate inspection is unavailable during loading, across an origin change, or without HTTPS server trust. Same-origin path, query, and fragment changes retain access; WebKit trust and secure-content changes refresh the menu. Navigation, page hiding, replacement, and closure dismiss the sheet. Inspection makes no independent network request and cannot grant a certificate exception.

## Site domain labels

[[Sources/BrowseCore/SiteDisplayDomain.swift#SiteDisplayDomain]] abbreviates the toolbar label to the registrable domain using an offline Public Suffix List snapshot, including ICANN and private rules.

The formatter applies longest-match, wildcard, and exception rules, normalizing international names to ASCII. IP addresses and single-label hosts remain intact. The full origin stays in the menu and tooltip; permission and certificate identities are unchanged. [[scripts/update-public-suffix-list.py]] refreshes [[Sources/BrowseCore/PublicSuffixSnapshot.swift]] from the official list, preserving its source and license notices without runtime network requests. [[lat.md/tests/web-pages-tests#Site domain labels]] covers boundary cases.
