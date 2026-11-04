# Architecture

Browse is a native macOS prototype combining SwiftUI browser chrome, an AppKit window, and system WebKit pages in nested tiling layouts.

## Development signing

[build-app.sh](../scripts/build-app.sh) packages the release executable as Browse.app and signs it with the persistent Browse Dev identity from the keychain.

The script verifies the signature before reporting success and does not fall back to ad-hoc signing. Reusing the same certificate and bundle identifier preserves code identity across rebuilds so existing keychain authorizations can remain valid.

## Application shell

[BrowseApp.swift](../Sources/Browse/BrowseApp.swift) owns the native window, menus, keyboard shortcuts, and application lifetime. [BrowserView.swift](../Sources/Browse/BrowserView.swift) renders a dark workspace sidebar, vertical tabs, pane controls, and start pages.

Each workspace contains tabs; each tab contains one or more browser panes. Sidebar selection changes the displayed tab. The app creates a replacement tab when the last tab in a workspace closes. The sidebar has a fixed width and can be hidden. Its space is reserved for workspace and tab controls, with session-save errors shown at the bottom only when needed.

The sidebar header places workspace creation beside a right-aligned sidebar toggle, without a brand label. Panes start at the top window inset with no shared navigation bar. When the sidebar is hidden, the upper-left pane reserves space for window controls and exposes the sidebar toggle.

Each pane has one compact title row with reload/stop, split, zoom, and close controls. Reload focuses its pane and becomes stop while loading; it is disabled on start pages. The persistent address row is replaced by the [[architecture#Location popup]]. Back/forward remain available through the View menu and shortcuts; tab creation remains in the sidebar and File menu.

[BrowseApp.swift](../Sources/Browse/BrowseApp.swift) attaches an empty unified native toolbar to give the traffic lights standard toolbar-height spacing. AppKit manages their placement through resizing and full-screen transitions; the transparent titlebar has no separator or shared toolbar actions.

## Sidebar materials

The sidebar and exposed workspace share one native Liquid Glass base on macOS 26 and later. Selected tabs retain their capsule-shaped glass selection. Earlier systems use standard AppKit and SwiftUI materials.

[BrowseApp.swift](../Sources/Browse/BrowseApp.swift) hosts the entire SwiftUI workspace as the content of a regular native glass effect view. AppKit manages the glass/content geometry together; the transparent window supplies the outer corner clipping. The base spans the sidebar, titlebar area, and gaps around panes, including when the sidebar is hidden.

[BrowserView.swift](../Sources/Browse/BrowserView.swift) omits the legacy sidebar and canvas backdrops on macOS 26 and later so they do not cover the shared glass. Earlier systems retain behind-window sidebar and under-window materials that follow the window's active state. Selection has no custom fill or border, and pane chrome retains its separate darkened material.

## Pane materials

Browser panes use rounded native Liquid Glass panels on macOS 26 and later, with standard material on older systems. Focus is indicated by a brighter title and dimming of inactive panes.

[BrowserView.swift](../Sources/Browse/BrowserView.swift) dims inactive panes, including chrome and page content, with an 8% black overlay. Focus changes fade the overlay in or out over 100 ms. The overlay ignores hit testing and accessibility so underlying controls remain usable.

[BrowserView.swift](../Sources/Browse/BrowserView.swift) places the pane canvas over the shared [[architecture#Sidebar materials|app base material]]. Pane chrome and built-in pages reveal the panel material; web pages keep their own rendering. A narrow content inset sits behind an opaque neutral rim on the native clipping layer, covering bright glass bevels and page colors at the rounded edge. Pane materials have a 50% black scrim beneath foreground controls and content, reducing glass brightness without dimming text or web pages.

On macOS 26 and later, each live web page extends behind its compact title row, which uses native regular Liquid Glass. Scrolling page colors show through the header while its controls remain readable. The measured header height sets WebKit's obscured content inset, keeping fixed and sticky site elements below the controls. Start pages, errors, and older macOS versions retain the stacked header layout.

Each web view fills its pane's viewport and scrolls its document internally through WebKit. Page content height does not size the web view or the pane. The outer canvas scrolls only when the split layout's minimum dimensions exceed the available window area.

The complete pane, including its outer glass background, header, and page, shares a rounded, layer-backed AppKit container. Clipping is applied after the pane background so its glass compositing layers cannot extend outside the silhouette. The header glass also has rounded top corners, and the clip follows pane resizing.

The web view has an additional native clip around its composited content: all corners under the glass header, or only the bottom corners in the stacked layout. Nested SwiftUI content inherits the pane's environment through its native host.

## Tiling model

[Session.swift](../Sources/BrowseCore/Session.swift) represents pane layouts as binary split trees. Splitting replaces the focused leaf; closing a leaf collapses its parent into the surviving sibling and repairs focus when necessary.

Splits carry an axis and fraction. [BrowserView.swift](../Sources/Browse/BrowserView.swift) draws draggable dividers, constrains pane minimum sizes, and scrolls oversized layouts. Zoom temporarily displays a single pane without modifying the saved split tree.

## Pane layout animation

[PaneGeometry.swift](../Sources/BrowseCore/PaneGeometry.swift) resolves the split tree into flat pane and divider frames. [BrowserView.swift](../Sources/Browse/BrowserView.swift) keeps pane views keyed by page identity as their positions and sizes change.

Adding a pane animates existing frames over 180 ms with an ease-out curve. The new pane reveals horizontally for a right split or vertically for a lower split, without scaling its text or web content. The scroll view reveals the destination when it would extend beyond the viewport. Reduce Motion disables these layout and insertion animations.

The geometry retains pane minimum sizes and divider constraints, growing the scrollable canvas when necessary. Divider dragging updates immediately. Tab switches and session restoration start at their final layout; animation state is not persisted.

## WebKit integration

[BrowserStore.swift](../Sources/Browse/BrowserStore.swift) retains one WebKit controller per visited pane, keeping live pages and navigation history while switching tabs or changing layouts. The native host uses the system WebKit framework, not an embedded Safari application.

All panes share the app’s default persistent WebKit website data store, separate from Safari. Navigation updates the stored address and first-pane tab title. Command-clicking an HTTP or HTTPS link opens and focuses a new pane to the right of its source, leaving the source page unchanged and exiting pane zoom. This also applies to links targeting a new window; other new-window web links create tabs. Errors offer retry, and page JavaScript alert, confirm, and text-input dialogs use AppKit.

Command-click routing uses WebKit's navigation-action modifiers and left-button mask in both navigation policy and new-window callbacks. It cancels source navigation when opening a pane; plain clicks and non-link navigation retain their normal behavior.

Pane headers display full-color site favicons discovered from the completed document's icon links, then touch icons, then the origin's `/favicon.ico`. [FaviconLoader.swift](../Sources/Browse/FaviconLoader.swift) resolves and deduplicates candidates, bounds downloads, and uses an ephemeral cookie-free session with an in-memory HTTP cache. Missing or invalid icons use a site initial; internal pages retain their app symbols. Navigation clears the old icon and cancels pending work so stale results cannot replace the next page's icon.

External custom URL schemes are not handed to other applications. Downloads, website media permissions, Safari extensions, and Safari session sharing are outside the implemented prototype.

## Session restoration

[BrowserStore.swift](../Sources/Browse/BrowserStore.swift) debounces atomic JSON saves to the app’s Application Support directory and saves on normal termination. [Session.swift](../Sources/BrowseCore/Session.swift) checks restored tab, focus, and pane identity consistency before accepting state.

Persistence includes workspaces, selected tab, URLs, focused panes, and split trees. Restarting recreates web views from URLs; in-page state and back-forward lists are only retained during the running process. Invalid session files fall back to the initial workspace. Save failures appear in the sidebar.

## Browsing history

[History.swift](../Sources/BrowseCore/History.swift) models a bounded, serializable collection of web visits. It normalizes HTTP and HTTPS addresses, strips embedded credentials, and combines rapid consecutive visits to the same URL.

Visits retain titles and timestamps, newest first, up to 10,000 visits. Consecutive visits to the same URL within 30 seconds coalesce. Removing a URL also removes its learned suggestion choices; clearing history removes both visits and choices.

[BrowserStore.swift](../Sources/Browse/BrowserStore.swift) records successful web navigations. Later URL changes on a completed, idle page create visits, while title changes update the latest matching visit. Internal pages and failed navigations are excluded.

[BrowserStore.swift](../Sources/Browse/BrowserStore.swift) persists visits and learned choices atomically in a separate history file beside the session file. Writes are debounced and flushed with session saves; removal and clearing save immediately. An unreadable history file is preserved until an explicit clear permits replacement, with errors exposed by the store.

## History interface

[HistoryView.swift](../Sources/Browse/HistoryView.swift) displays searchable visits grouped by local calendar day in the built-in history page, with controls to revisit or remove pages and clear recorded history.

The History menu and Command-Y open `browse://history`, reusing an existing history pane across workspaces when available. Selecting a visit navigates the current pane; its context menu can open a new tab. Removing a page deletes all visits and learned choices for that URL. Clearing all history requires confirmation and leaves open pages and website data intact. The view displays history read and write errors from the store.

## History suggestions

[History.swift](../Sources/BrowseCore/History.swift) groups visits by URL and ranks matching suggestions using prior choices, URL match strength, and visit frequency weighted by recency.

Matching ignores case and diacritics and requires every query word to occur in the title or decoded URL. URL-prefix completions preserve the typed prefix; whitespace-containing queries do not receive inline completions.

Suggestions combine visits into one result per URL. Ranking prefers learned query choices, then exact or prefix URL matches, then frequency with a 30-day recency half-life. Learned choices are bounded to 1,000 query/URL pairs and decay over time. Matching runs locally without sending partial queries to a search engine or preloading pages.

The interaction draws on [Firefox's address-bar matching](https://support.mozilla.org/en-US/kb/address-bar-autocomplete-firefox), its [frequency/recency and adaptive-input ranking](https://firefox-source-docs.mozilla.org/browser/urlbar/ranking.html), and [Safari's combined search field](https://support.apple.com/en-ie/guide/safari/sfrid73436cb/mac). Browse implements its own bounded ranking over recorded visits.

[AddressPanelController.swift](../Sources/Browse/AddressPanelController.swift) combines history matches with a direct visit or search action in the [[architecture#Location popup]]. The popup refreshes when history changes; selecting a history result records the typed query to influence later rankings.

## Address handling

[Session.swift](../Sources/BrowseCore/Session.swift) resolves web addresses, localhost development URLs, built-in start pages, and search queries. Explicit non-web schemes are rejected; search text is encoded as a Google query parameter.

Bare hostnames containing dots use HTTPS, while localhost and loopback IPv4 addresses use HTTP. [BrowserStore.swift](../Sources/Browse/BrowserStore.swift) also limits WebKit navigation to web URLs and internal blank documents.

## Location popup

[AddressPanelController.swift](../Sources/Browse/AddressPanelController.swift) owns a floating, Spotlight-style native location panel. URL entry is separate from pane chrome.

Command-L and the start-page location button open the popup for a specific pane, with its current URL selected (blank for start pages). Return navigates that pane using the [[architecture#Address handling|address resolver]]; invalid input stays open with an error that clears when editing resumes.

[AddressPanelController.swift](../Sources/Browse/AddressPanelController.swift) displays [[architecture#History suggestions]] beneath the input. Arrow keys select results, Return opens the selection, and clicking a result opens it. Eligible URL prefixes autocomplete with the added suffix selected; deletion, marked text input, and edits away from the end suppress autofill.

Opening the popup shows frequent/recent pages while retaining the current address selected for editing. Typing shows up to six history matches alongside an explicit visit/search action. Inline URL matches become the selected top result; other queries keep the explicit action selected. History updates preserve selection when possible, and deletion removes stale suggestions immediately. Results sit directly beneath the input with compact spacing; validation errors reserve extra space only while visible.

The popup is a borderless child panel positioned near the main window's upper center. It uses native HUD material with a 50% black background scrim, accepts keyboard focus without becoming the main window, supports full-screen use, and hides when the app deactivates.

A stretchable rounded material mask shapes both the backdrop and the native window shadow. The dark scrim uses the same corner radius, keeping it inside the material's outline as the popup width changes.

Selected suggestions use a rounded native clear-glass background on macOS 26 and later, with a subtle translucent fill on earlier systems. The selection keeps the compact row alignment and leaves keyboard focus in the address input.

Escape dismisses the popup and returns keyboard focus to the browser, as does successful submission. Losing key-window status dismisses it without reclaiming focus, allowing outside clicks to select another pane or application normally.

[BrowserStore.swift](../Sources/Browse/BrowserStore.swift) requests the popup after creating blank split panes, tabs, workspaces, or a replacement for the last closed tab. Link-created panes and tabs already have a destination and do not prompt. Popup requests validate pane identity; submitting after the target has closed or left the selected tab cannot navigate another pane.

[BrowseApp.swift](../Sources/Browse/BrowseApp.swift) connects the store's location-request callback to the panel controller. Requests carry a pane identity after the store has updated selection and focus, so presentation does not depend on a newly created SwiftUI pane observing an earlier event.
