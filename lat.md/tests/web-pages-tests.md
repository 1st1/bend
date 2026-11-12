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
