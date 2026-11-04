# Architecture

Browse is a native macOS prototype combining SwiftUI browser chrome, an AppKit window, and system WebKit pages in nested tiling layouts.

## Application shell

[BrowseApp.swift](../Sources/Browse/BrowseApp.swift) owns the native window, menus, keyboard shortcuts, and application lifetime. [BrowserView.swift](../Sources/Browse/BrowserView.swift) renders a dark workspace sidebar, vertical tabs, pane controls, and start pages.

Each workspace contains tabs; each tab contains one or more browser panes. Sidebar selection changes the displayed tab. The app creates a replacement tab when the last tab in a workspace closes. The sidebar has a fixed width and can be hidden.

The sidebar header places workspace creation beside a right-aligned sidebar toggle, without a brand label. Panes start at the top window inset with no shared navigation bar. When the sidebar is hidden, the upper-left pane reserves space for window controls and exposes the sidebar toggle.

Each pane has one compact title row with reload/stop, split, zoom, and close controls. Reload focuses its pane and becomes stop while loading; it is disabled on start pages. The persistent address row is replaced by the [[architecture#Location popup]]. Back/forward remain available through the View menu and shortcuts; tab creation remains in the sidebar and File menu.

[BrowseApp.swift](../Sources/Browse/BrowseApp.swift) attaches an empty unified native toolbar to give the traffic lights standard toolbar-height spacing. AppKit manages their placement through resizing and full-screen transitions; the transparent titlebar has no separator or shared toolbar actions.

## Sidebar materials

The sidebar uses AppKit’s native sidebar material, while the selected tab uses a capsule-shaped SwiftUI Liquid Glass effect on macOS 26 and later. Earlier systems use a standard SwiftUI material selection.

[BrowserView.swift](../Sources/Browse/BrowserView.swift) supplies the system materials without a custom selection fill or border. The sidebar blends behind the window and follows its active state. [BrowseApp.swift](../Sources/Browse/BrowseApp.swift) keeps the window background transparent.

## Pane materials

Browser panes use rounded native Liquid Glass panels on macOS 26 and later, with standard material on older systems. Focus is indicated by a neutral header dot and brighter title rather than a colored border.

[BrowserView.swift](../Sources/Browse/BrowserView.swift) dims inactive panes, including chrome and page content, with an 8% black overlay. Focus changes fade the overlay in or out over 100 ms. The overlay ignores hit testing and accessibility so underlying controls remain usable.

[BrowserView.swift](../Sources/Browse/BrowserView.swift) places the pane canvas over an AppKit window material. Pane chrome and built-in pages reveal the panel material; web pages keep their own rendering. A narrow content inset exposes the system glass edge without drawing a custom outline. Pane materials have a 50% black scrim beneath foreground controls and content, reducing glass brightness without dimming text or web pages.

On macOS 26 and later, each live web page extends behind its compact title row, which uses native regular Liquid Glass. Scrolling page colors show through the header while its controls remain readable. The measured header height sets WebKit's obscured content inset, keeping fixed and sticky site elements below the controls. Start pages, errors, and older macOS versions retain the stacked header layout.

## Tiling model

[Session.swift](../Sources/BrowseCore/Session.swift) represents pane layouts as binary split trees. Splitting replaces the focused leaf; closing a leaf collapses its parent into the surviving sibling and repairs focus when necessary.

Splits carry an axis and fraction. [BrowserView.swift](../Sources/Browse/BrowserView.swift) draws draggable dividers, constrains pane minimum sizes, and scrolls oversized layouts. Zoom temporarily displays a single pane without modifying the saved split tree.

## WebKit integration

[BrowserStore.swift](../Sources/Browse/BrowserStore.swift) retains one WebKit controller per visited pane, keeping live pages and navigation history while switching tabs or changing layouts. The native host uses the system WebKit framework, not an embedded Safari application.

All panes share the app’s default persistent WebKit website data store, separate from Safari. Navigation updates the stored address and first-pane tab title. Command-clicking an HTTP or HTTPS link opens and focuses a new pane to the right of its source, leaving the source page unchanged and exiting pane zoom. This also applies to links targeting a new window; other new-window web links create tabs. Errors offer retry, and page JavaScript alert, confirm, and text-input dialogs use AppKit.

External custom URL schemes are not handed to other applications. Downloads, website media permissions, Safari extensions, and Safari session sharing are outside the implemented prototype.

## Session restoration

[BrowserStore.swift](../Sources/Browse/BrowserStore.swift) debounces atomic JSON saves to the app’s Application Support directory and saves on normal termination. [Session.swift](../Sources/BrowseCore/Session.swift) checks restored tab, focus, and pane identity consistency before accepting state.

Persistence includes workspaces, selected tab, URLs, focused panes, and split trees. Restarting recreates web views from URLs; in-page state and back-forward lists are only retained during the running process. Invalid session files fall back to the initial workspace. Save failures appear in the sidebar.

## Address handling

[Session.swift](../Sources/BrowseCore/Session.swift) resolves web addresses, localhost development URLs, built-in start pages, and search queries. Explicit non-web schemes are rejected; search text is encoded as a Google query parameter.

Bare hostnames containing dots use HTTPS, while localhost and loopback IPv4 addresses use HTTP. [BrowserStore.swift](../Sources/Browse/BrowserStore.swift) also limits WebKit navigation to web URLs and internal blank documents.

## Location popup

[AddressPanelController.swift](../Sources/Browse/AddressPanelController.swift) owns a floating, Spotlight-style native location panel. URL entry is separate from pane chrome.

Command-L and the start-page location button open the popup for a specific pane, with its current URL selected (blank for start pages). Return navigates that pane using the [[architecture#Address handling|address resolver]]; invalid input stays open with an error that clears when editing resumes.

The popup is a borderless child panel positioned near the main window's upper center. It uses native HUD material with a 50% black background scrim, accepts keyboard focus without becoming the main window, supports full-screen use, and hides when the app deactivates.

Escape dismisses the popup and returns keyboard focus to the browser, as does successful submission. Losing key-window status dismisses it without reclaiming focus, allowing outside clicks to select another pane or application normally.

[BrowserStore.swift](../Sources/Browse/BrowserStore.swift) requests the popup after creating blank split panes, tabs, workspaces, or a replacement for the last closed tab. Link-created panes and tabs already have a destination and do not prompt. Popup requests validate pane identity; submitting after the target has closed or left the selected tab cannot navigate another pane.

[BrowseApp.swift](../Sources/Browse/BrowseApp.swift) connects the store's location-request callback to the panel controller. Requests carry a pane identity after the store has updated selection and focus, so presentation does not depend on a newly created SwiftUI pane observing an earlier event.
