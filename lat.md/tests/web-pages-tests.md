---
lat:
  require-code-mention: true
---
# Web pages tests

Tests verify webKit ownership, page printing, and JavaScript dialogs.

See [[lat.md/architecture/web-pages|Architecture and behavior]].

## JavaScript dialog origin and responses

[javaScriptDialogOriginAndResponses](../../Tests/BrowseTests/JavaScriptDialogTests.swift) verifies all dialog kinds use a real subframe's origin, preserve alert/confirm/prompt completion semantics, and label local or opaque origins safely.

## JavaScript dialog admission and rate limits

[javaScriptDialogAdmissionAndLimits](../../Tests/BrowseTests/JavaScriptDialogTests.swift) rejects hidden and background-window callers, coalesces pending requests, isolates windows, and verifies rolling limits survive navigation while user suppression resets on commit.

## JavaScript dialog lifecycle cancellation

[javaScriptDialogLifecycleCancellation](../../Tests/BrowseTests/JavaScriptDialogTests.swift) verifies navigation, ancestor hiding, detachment, process termination, and window closure cancel prompts exactly once, even if a stale sheet callback later reports acceptance.

## JavaScript native sheets

[javaScriptNativeSheets](../../Tests/BrowseTests/JavaScriptDialogTests.swift) verifies a real AppKit prompt attaches to its browser window, returns entered text, and leaves the application outside an application-modal event loop.

## Page printing

[[Tests/BrowseTests/PrintingTests.swift#pagePrinting]] dispatches Command-P and File → Print through native menus, verifies the focused pane supplies the job, cancels real print sheets, and checks disabled states without sending anything to a printer.

## Website permission isolation

[[Tests/BrowseTests/WebsitePermissionTests.swift#websitePermissionIsolation]] verifies default prompts, saved grants, Ask resets, combined-request denial, frame isolation, distinct ports, non-web denial, and temporary private settings.

## Website upload lifecycle

[[Tests/BrowseTests/WebsitePermissionTests.swift#websiteUploadLifecycle]] verifies directory and multiple-selection configuration, concurrent-request rejection, cancellation exactly once, ignored late acceptance, and hidden-page rejection.

It also verifies Objective-C selector visibility and a real WebKit file input opening a native panel, then cancels it.

## Permission delegate frame identity

[[Tests/BrowseTests/WebsitePermissionTests.swift#websitePermissionDelegateFrameIdentity]] exercises media and both geolocation callbacks with real frame origins to reject inherited grants, honor child blocks, and deny opaque callers.

Same-origin grants remain usable. A child with its own saved Allow still needs a prompt, and blocking the top-level site denies requests from both origins.

## Immediate capture revocation

[[Tests/BrowseTests/WebsitePermissionTests.swift#websitePermissionImmediateRevocation]] verifies that blocking camera or microphone immediately sends stop commands to every matching pane, without stopping unrelated panes or the other device.

Unrelated settings updates do not repeat stops, and resetting a choice to Ask permits a later Block to revoke again. The test intercepts WebKit capture commands without accessing real devices.

## Remembered permission prompts

[[Tests/BrowseTests/WebsitePermissionTests.swift#websitePermissionRememberPrompt]] verifies explicit remembered Allow/Block responses, cancellation without saving, ignored late callbacks, and no remember option for third-party frames.

## Removing saved website permissions

[[Tests/BrowseTests/WebsitePermissionTests.swift#websitePermissionRemoval]] verifies that removing a site persists Ask for every permission, preserves another port’s permissions, and leaves hostname zoom unchanged.

## Certificate site identity

[[Tests/BrowseTests/WebsitePermissionTests.swift#certificateSiteIdentity]] verifies same-origin path, query, and fragment changes retain certificate access while different hosts, ports, schemes, and missing URLs do not.

## Site domain labels

[[Tests/BrowseCoreTests/SiteDisplayDomainTests.swift#siteDisplayDomainLabels]] verifies ordinary and multi-part suffixes, private hosting, wildcard exceptions, international names, trailing dots, unknown suffixes, IP addresses, and localhost.
