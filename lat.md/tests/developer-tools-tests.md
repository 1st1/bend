---
lat:
  require-code-mention: true
---
# Developer tools tests

Tests verify web inspection and opt-in native input diagnostics.

See [[lat.md/architecture/developer-tools|Architecture and behavior]].

## Input logging preference

[InputDiagnosticsTests.swift](../../Tests/BrowseTests/InputDiagnosticsTests.swift) verifies logging defaults off, enabling records both streams, the preference survives recreation, and disabling preserves files without appending events.

## Input trace rotation

[InputDiagnosticsTests.swift](../../Tests/BrowseTests/InputDiagnosticsTests.swift) verifies native input logs retain recent complete records within two bounded files, including after a writer is recreated.

The test checks repeated rotation discards the oldest segment, oversized records are rejected, queued writes drain, and both files have private permissions.

## Independent input and pane log retention

[InputDiagnosticsTests.swift](../../Tests/BrowseTests/InputDiagnosticsTests.swift) verifies heavy input traffic cannot rotate pane activity away, and adopting a smaller size cap removes oversized legacy segments.

## Pane trace correlation

[InputDiagnosticsTests.swift](../../Tests/BrowseTests/InputDiagnosticsTests.swift) verifies the press pane survives hiding/removal through release, the receiving pane is reported separately, and a new non-pane press resets attribution.

Both streams share run and sequence identifiers. The trace includes pane attachment and movement activity, preserves all drag events, and excludes keyboard input. Web-view replacement preserves the pane UUID while changing native view identity.

## Input diagnostics during hosting teardown

[InputDiagnosticsTests.swift](../../Tests/BrowseTests/InputDiagnosticsTests.swift) destroys real hosting views with tracing active, exercising pane-handle dismantling while their hosting ancestor is deallocating.

Repeated creation and destruction must finish without an Objective-C weak-registration abort. Hosting views and handles must be released, and each dismantled pane handle must produce a removal record with its pane UUID.

## Developer tools

[DeveloperToolsTests.swift](../../Tests/BrowseTests/DeveloperToolsTests.swift) opens the native inspector through the Develop menu shortcut and checks that console errors, thrown errors, and unhandled rejections from the selected pane reach its console.

Two mounted pages verify source isolation and focused-pane routing. Command-Shift-I toggles the inspector below its page in the same pane. The native toolbar switches between right and bottom docking without losing console messages, and its close button removes the panel. Inspecting a real DOM element before docking, plus a repeated native reveal in a narrow page, must keep the frontend in its original panel and window with no empty dock region. Mouse drags resize both dock positions without moving the browser window. Reopening and find-bar coexistence preserve separate page/inspector bounds, including narrow panes. The inspector control bridge is absent from the inspected website. Left docking and detaching stay hidden; closure removes the frontend, and commands disable on native Bend pages. `BEND_INSPECTOR_SNAPSHOT` optionally captures the containing browser window. Run this AppKit test without parallel execution because it owns the shared application menu.
