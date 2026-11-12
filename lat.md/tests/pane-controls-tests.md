---
lat:
  require-code-mention: true
---
# Pane controls tests

Tests verify pane toolbar appearance, navigation controls, pins, and return destinations.

See [[lat.md/architecture/pane-controls|Architecture and behavior]].

## Pane history controls

[PaneNavigationTests.swift](../../Tests/BrowseTests/PaneNavigationTests.swift) verifies Back/Forward through the mounted browser shell using local pages and native mouse events.

The complete focused toolbar stays visible; inactive pane buttons appear together on whole-pane hover without shifting the title or stealing focus. Disabled clicks do not navigate. History clicks focus and navigate only their own pane, preserving other page state. Window deactivation and hidden tabs clear hover, while reactivation refreshes it.

Long titles fill the available header width without overlapping or pushing out the trailing buttons at different window sizes.

## Pinned pane protection

[[Tests/BrowseTests/PinningTests.swift#pinnedPaneProtection]] verifies pins survive reload, older pages default to unpinned, and protected pane/tab closure preserves controllers, layout, zoom, and closed history.

Tab pinning sets all pane pins; individual unpinning keeps the tab protected while any pin remains. Unpinned siblings can close and reopen. Pinned blank-entry and download tabs survive automatic cleanup, and reopening a closed tab retains a pinned replacement.

## Pinned pane transfers

[[Tests/BrowseTests/PinningTests.swift#pinnedPaneTransfers]] moves a pinned pane across tabs, detaches and rejoins it, then transfers it between windows, preserving its pin, live WebView, session validity, and persisted state without closed history.

## Pinned close commands

[[Tests/BrowseTests/PinningTests.swift#pinnedCloseCommands]] verifies Command-W cannot close the final pinned pane's window, native close requests are refused while pinned, and unpinning restores normal last-pane window closure.

## Native pin controls

[[Tests/BrowseTests/PinningTests.swift#nativePinControls]] exercises native Option-clicks on pane controls and sidebar rows, checks the live modifier preview, returns an inactive pane to its pinned URL, and unpins an inactive pane and an unselected tab through their always-visible pin buttons.

## Pinned URL return

[[Tests/BrowseTests/PinningTests.swift#pinnedURLReturn]] verifies pin-time URL capture, away-state detection, same-controller return, tab pin preservation, repinning, session restoration, and migration of older pins. The command popup test exercises the return action.
