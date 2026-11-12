# Pane controls

Pane toolbar appearance, navigation controls, pins, and return destinations.

See [[lat.md/tests/pane-controls-tests|Test coverage]].

## Toolbar button styling

[ChromeButtonStyle.swift](../../Sources/Browse/ChromeButtonStyle.swift) gives pane controls, find buttons, the media picker, and the extension menu a shared appearance, with semantic foreground levels and subtle circular hover backgrounds shared with the pane title pill.

Pane controls use regular 12-point symbols on a 24-point pitch, with a 22-point hover circle. Pane pin symbols use 11 points to balance their tall, dense shape while retaining the same click target. The title pill and controls are vertically centered in the full 36-point pane header; the loading strip overlays it without shifting the control row upward. The loading strip uses the macOS control accent color. Enabled pane and sidebar icons use the system secondary foreground, becoming primary on hover or press; Increase Contrast also uses primary. Disabled icons use tertiary without an extra opacity multiplier and do not highlight. These hierarchical styles replace fixed RGB colors so system appearance and material foreground treatment remain available. The browser root does not override the inherited foreground with a custom color. Hover reveals a semantic primary background at 6% opacity over 100 ms. Only the background animates; label foreground changes apply immediately, avoiding a text crossfade during hover or press. Sidebar header controls share the same foreground states, with a larger 14-point symbol and 28-point circle. [[Sources/Browse/DownloadsButton.swift#DownloadProgressIcon]] inherits this treatment for its idle icon and active arrow instead of overriding it with fixed white opacity; the progress arc retains its accent color. Reduce Motion removes state-transition animations. The extension menu uses the button menu style so it receives the same sizing and interaction treatment as adjacent buttons. The media picker and Downloads Clear button use content-width capsules with the same hover fill and foreground states. Native menu tracking clears cached hover when it begins and ends, preventing a missed mouse-exit event from leaving the extension button highlighted after dismissal.

## Pane navigation controls

Pane buttons in [BrowserView.swift](../../Sources/Browse/BrowserView.swift) stay visible for the focused pane and appear together on inactive panes while the pointer is anywhere inside them.

The title precedes Back/Forward, reload/stop, and the extensions/zoom/close group. Twelve-point gaps separate these groups, giving adjacent button centers a 36-point pitch across boundaries versus 24 points within groups. The title has the same minimum gap before the toolbar. The pane zoom button is omitted for single-pane tabs and remains available when a multi-pane tab is zoomed.

Pane titles use the available width before the fixed-size toolbar, with a single-line trailing ellipsis when necessary. Short titles keep a compact hover pill; long titles have no arbitrary width cap and cannot overlap the controls. The entire toolbar reserves its space when hidden, preventing title movement. Hidden controls neither accept clicks nor appear in accessibility. Visibility fades over 100 ms, or changes immediately with Reduce Motion. Window-level sidebar and download controls remain available independently.

Unavailable history directions and internal start pages disable Back/Forward. Enabled clicks focus their pane and navigate its own WebKit history; [BrowserStore.swift](../../Sources/Browse/BrowserStore.swift) observes history availability directly.

Native pane tracking covers web content, headers, and docked developer tools without intercepting input. It clears hover when hidden, removed, or the window deactivates, and refreshes on layout and window activation. Hover callbacks defer SwiftUI state updates until after native layout. [[lat.md/tests/pane-controls-tests#Pane history controls]] verifies navigation and visibility through the mounted browser shell.

## Pinned panes and tabs

[[Sources/BrowseCore/Session.swift#Page]] persists each pane's pin and the URL captured when pinning. [[Sources/BrowseCore/Session.swift#BrowserTab]] is pinned whenever any of its panes is pinned, protecting the tab from closure without a separate tab-level flag.

[[Sources/Browse/PinCloseButton.swift#PinCloseButton]] previews a pin in place of close while Option is held. Option-click pins an ordinary pane; a pinned pane always displays a filled pin, including when inactive or unhovered, and clicking it unpins without closing. Other inactive header controls remain hidden. [[Sources/Browse/PinCloseButton.swift#OptionKeyState]] tracks modifier changes locally, including while the pointer is stationary, and resynchronizes when the app activates or the pointer enters a button.

The sidebar uses the same close/pin control. Option-clicking that control or the tab row pins every current pane. Clicking an existing sidebar pin unpins every pane. The sidebar pin stays visible on unselected, unhovered tabs if any pane remains pinned; individual panes can be unpinned independently. Context menus also offer Pin/Unpin and disable Close for protected tabs. Newly created panes start unpinned, and pins do not reorder tabs or prevent navigation.

[[Sources/Browse/BrowserStore.swift#BrowserStore#setPanePinned]] and [[Sources/Browse/BrowserStore.swift#BrowserStore#setTabPinned]] update saved state without replacing controllers or changing selection. Pane/tab close methods reject protected targets before altering layout, focus, zoom, controllers, or closed history. Keyboard/menu closes, extension pane-close requests, blank-entry cancellation, initial-download cleanup, and replacement-tab cleanup respect pins. Extension close reports an error for a protected pane. Native window close requests are refused while any tab contains a pin; normal application quit still saves the open windows and pins.

[[Sources/Browse/BrowserStore.swift#BrowserStore#pinnedReturnAddress]] detects when a pinned pane has navigated away from its captured URL. An always-visible return button beside the pane pin and the Return to Pinned URL command navigate that same pane back, preserving its pin and controller. Unpinning clears the captured URL; pinning again captures the current address. Pinning a whole tab preserves existing pinned destinations. Older pinned pages use their saved address as the initial destination. [[lat.md/tests/pane-controls-tests#Pinned URL return]] covers capture, return, repinning, and restoration.

Pin state follows the page through reordering, splitting, detaching, joins, and cross-window transfers. Structural removal during a transfer preserves the pinned page at its destination rather than closing it. Missing pin fields in older sessions default to unpinned. [[lat.md/tests/pane-controls-tests#Pinned pane protection]], [[lat.md/tests/pane-controls-tests#Pinned pane transfers]], [[lat.md/tests/pane-controls-tests#Pinned close commands]], and [[lat.md/tests/pane-controls-tests#Native pin controls]] cover persistence, close paths, moves, and native interactions.
