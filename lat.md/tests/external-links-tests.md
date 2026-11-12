---
lat:
  require-code-mention: true
---
# External links tests

Tests verify default browser registration, local documents, and external application consent.

See [[lat.md/architecture/external-links|Architecture and behavior]].

## Default browser selection

[DefaultBrowserTests.swift](../../Tests/BrowseTests/DefaultBrowserTests.swift) verifies both web schemes are required for default status, combined system changes avoid duplicate requests, and cancellation and failure leave the control ready to retry.

Injected handler queries and requests keep these tests from changing the user's actual default browser. Refresh detects changes made outside Bend; failure produces an error while cancellation does not.

## External web links

[DefaultBrowserTests.swift](../../Tests/BrowseTests/DefaultBrowserTests.swift) verifies web URLs received before launch finishes open after restoration, later links target the active window, and existing tabs remain intact.

Multiple URLs preserve order, query strings, and fragments. Unsupported schemes are ignored, the pending queue drains once, and external links do not open a blank address popup.

## External application consent

[ExternalApplicationLinkTests.swift](../../Tests/BrowseTests/ExternalApplicationLinkTests.swift) verifies generic custom schemes open only after approval, preserve the destination URL, and use the resolved application shown in the prompt.

Cancellation never launches an app. Missing handlers and launch failures are reported, internal schemes are excluded, and the displayed page origin omits credentials and URL payloads. App lookup, confirmation, and launch are injected so tests never open a real external app.

## External application prompt coalescing

[ExternalApplicationLinkTests.swift](../../Tests/BrowseTests/ExternalApplicationLinkTests.swift) verifies repeated requests share no queue: a pending window blocks a second prompt, cancellation permits retry, and a hidden window cannot launch an app.

The test holds the confirmation asynchronously to exercise requests arriving before the first decision and window hiding before approval completes.

## WebKit external application routes

[ExternalApplicationLinkTests.swift](../../Tests/BrowseTests/ExternalApplicationLinkTests.swift) exercises real WebKit normal links, scripted redirects, new-window links, and iframe launchers using a synthetic custom scheme.

Each navigation produces exactly one mocked app launch, preserves the source document without a navigation error, identifies the source origin, and does not create an empty browser tab.

## Local web documents

[DefaultBrowserTests.swift](../../Tests/BrowseTests/DefaultBrowserTests.swift) verifies local HTML received through the app delegate loads with relative JavaScript assets and survives recreation from the saved file URL.

HTML and XHTML are accepted, while other file types and remote file hosts are rejected. Directory containment rejects paths outside the document’s directory.
