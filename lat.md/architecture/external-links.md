# External links

Default browser registration, local documents, and external application consent.

See [[lat.md/tests/external-links-tests|Test coverage]].

## External application links

[ExternalApplicationLinks.swift](../../Sources/Browse/ExternalApplicationLinks.swift) lets pages launch installed apps through custom URL schemes after an explicit native confirmation, without app-specific routing rules.

[BrowserStore.swift](../../Sources/Browse/BrowserStore.swift) intercepts external schemes in navigation policy and new-window callbacks. Normal links, scripted navigation, iframe launchers, and new-window links all preserve the source document and do not create empty tabs. Internal, web, file, script, data, blob, and extension schemes retain their existing handling and never reach the external opener. Detached or hidden page views cannot present a launch prompt.

NSWorkspace resolves the registered application. The confirmation shows its name and icon and the initiating page’s origin, omitting URL credentials, paths, queries, and fragments. Approval opens the original URL in that exact application; cancellation does nothing. No persistent launch permission is granted. Missing handlers and launch failures show a native explanation without replacing the source page. Bend is excluded as its own external handler to avoid loops.

Only one request per window may be pending; other requests are discarded rather than queued behind a sheet. Closing or hiding the window before approval prevents the launch. [[lat.md/tests/external-links-tests#External application consent]], [[lat.md/tests/external-links-tests#External application prompt coalescing]], and [[lat.md/tests/external-links-tests#WebKit external application routes]] cover the flow with mocked app launches and real WebKit navigation.

## Default browser

[DefaultBrowser.swift](../../Sources/Browse/DefaultBrowser.swift) adds a default-browser status and Make Default action at the top of Settings → UI, using macOS's native consent flow.

Both HTTP and HTTPS must resolve to Bend's bundle identity for the status to report it as default. Status refreshes when the section appears, Bend becomes active, and a request completes. Requests use NSWorkspace's public asynchronous default-application API, rechecking each scheme so a combined system confirmation does not cause a redundant prompt. Cancellation shows no error; other failures appear inline and allow retry. The refreshed status reflects any scheme changes that completed before a cancellation or failure. Bend never requests this change automatically on launch.

[build-app.sh](../../scripts/build-app.sh) declares HTTP/HTTPS URL handling and HTML/XHTML document viewing. System Settings browser eligibility needs the document declarations as well as the URL schemes; checking only URL-handler registration is insufficient. [BrowseApp.swift](../../Sources/Browse/BrowseApp.swift) receives external web URLs and local HTML/XHTML files, queues requests until window restoration finishes, and opens each in a new tab in the active browser window, preserving existing tabs. Unsupported schemes, remote file hosts, other file types, and web URLs without hosts are ignored. [[lat.md/tests/external-links-tests#Default browser selection]] covers consent outcomes without changing the machine's default; [[lat.md/tests/external-links-tests#External web links]] covers launch-time queuing and active-window routing.

[LocalWebDocument.swift](../../Sources/Browse/LocalWebDocument.swift) identifies supported local documents. [BrowserStore.swift](../../Sources/Browse/BrowserStore.swift) loads them through WebKit’s file-loading API with read access limited to their containing directory, including relative assets. Local navigation is restricted to that directory and normal web navigation clears the scope. Saved local-document URLs restore through the same path. [[lat.md/tests/external-links-tests#Local web documents]] verifies loading and scope checks.
