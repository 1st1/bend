---
lat:
  require-code-mention: true
---
# Browser windows tests

Tests verify native application windows, fullscreen transitions, and window dragging.

See [[lat.md/architecture/windows|Architecture and behavior]].

## Independent browser windows

[BrowserWindowTests.swift](../../Tests/BrowseTests/BrowserWindowTests.swift) checks independent tabs and address panels, shared history updates and preferences, live glass propagation, and preservation of the other window's controllers and extension adapters on close.

## Browser window restoration

[BrowserWindowTests.swift](../../Tests/BrowseTests/BrowserWindowTests.swift) verifies per-window layouts and selection survive quit, closing one window removes it from restoration, final-window closure preserves it, and preferences persist after the primary closes.

The test also closes every registered extension window and opens a new one, checking that retired adapters stay detached and the shared manager registers the new window correctly.

## New window keyboard command

[BrowserWindowTests.swift](../../Tests/BrowseTests/BrowserWindowTests.swift) dispatches Command-N through the native menu, checks that it creates a separate blank browser window, and verifies tab commands follow focus between both windows.

Focus transitions use the native window delegate notification so offscreen desktop activation is not a prerequisite.

## Closing the last browser pane

[BrowserWindowTests.swift](../../Tests/BrowseTests/BrowserWindowTests.swift) verifies Command-W closes an exhausted window when another browser remains, but replaces the sole window’s last pane with a blank pane and focused address popup.

The closed page remains reopenable. Repeating Command-W from the popup keeps the sole browser open; explicit native closure still closes it, and close commands with no browser do not mutate saved state.

## Window control alignment

[[Tests/BrowseTests/BrowserWindowTests.swift#windowControlAlignment]] verifies native traffic lights align with pane titles in new regular and private windows, before and after resizing and sidebar toggles, while another window changes fullscreen toolbar visibility.

Both sidebar positions preserve upper-left traffic-light geometry and keep pane title hit regions clear of the controls in regular and private windows.

## Fullscreen chrome transitions

[BrowserWindowTests.swift](../../Tests/BrowseTests/BrowserWindowTests.swift) enters and exits native fullscreen, verifying toolbar auto-hiding, unobstructed title hit testing, sidebar toggles, restored windowed geometry, and retained document state.

Run with `BEND_FULLSCREEN_TEST=1` because the test activates a temporary app window and changes macOS Spaces. It checks full-height content layout, a compact rollover titlebar no taller than 32 points with vertically centered traffic lights, removal of traffic-light reservation in fullscreen, dismissal of an old address popup, and preservation of unsaved form data through exit. The original toolbar visibility and window-control position must return on exit.

## Page fullscreen availability

[ElementFullscreenTests.swift](../../Tests/BrowseTests/ElementFullscreenTests.swift) loads a browser page and verifies the document reports fullscreen enabled and exposes the video request API without entering fullscreen automatically.
