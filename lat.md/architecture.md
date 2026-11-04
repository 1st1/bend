# Architecture

Browse is a native macOS prototype combining SwiftUI browser chrome, an AppKit window, and system WebKit pages in nested tiling layouts.

## Development signing

[build-app.sh](../scripts/build-app.sh) packages the release executable as Browse.app and signs it with the persistent Browse Dev identity from the keychain.

The script verifies the signature before reporting success and does not fall back to ad-hoc signing. Reusing the same certificate and bundle identifier preserves code identity across rebuilds so existing keychain authorizations can remain valid.

## Application shell

[BrowseApp.swift](../Sources/Browse/BrowseApp.swift) owns the native window, menus, keyboard shortcuts, and application lifetime. [BrowserView.swift](../Sources/Browse/BrowserView.swift) renders a dark workspace sidebar, vertical tabs, pane controls, and start pages.

Each workspace contains tabs; each tab contains one or more browser panes. Sidebar selection changes the displayed tab. The app creates a replacement tab when the last tab in a workspace closes. The sidebar has a fixed width and can be hidden. Its space is reserved for workspace and tab controls, with session-save errors shown at the bottom only when needed.

The sidebar header places workspace creation beside a right-aligned sidebar toggle, without a brand label. Panes start at the top window inset with no shared navigation bar. When the sidebar is hidden, the upper-left pane reserves space for window controls and exposes the sidebar toggle.

Each pane has one compact title row with extensions, reload/stop, split, zoom, and close controls, using shared [[architecture#Toolbar button styling]]. Reload focuses its pane and becomes stop while loading; it is disabled on start pages. The persistent address row is replaced by the [[architecture#Location popup]]. Back/forward remain available through the View menu and shortcuts; tab creation remains in the sidebar and File menu.

[BrowseApp.swift](../Sources/Browse/BrowseApp.swift) attaches an empty unified native toolbar to give the traffic lights standard toolbar-height spacing. AppKit manages their placement through resizing and full-screen transitions; the transparent titlebar has no separator or shared toolbar actions.

## Toolbar button styling

[ChromeButtonStyle.swift](../Sources/Browse/ChromeButtonStyle.swift) gives pane controls and the extension menu a shared appearance, with muted cool-gray icons and translucent black circular hover backgrounds.

Pane controls use regular 12-point symbols on a 24-point pitch, with a 22-point hover circle. Hover or pressing brightens the icon and reveals a pure-black background at 20% opacity over 100 ms. Disabled controls stay dim and do not highlight. Sidebar header controls use a brighter 14-point symbol and a 28-point circle. Reduce Motion removes state-transition animations. The extension menu uses the button menu style so it receives the same sizing and interaction treatment as adjacent buttons. Native menu tracking clears cached hover when it begins and ends, preventing a missed mouse-exit event from leaving the extension button highlighted after dismissal.

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

## Reopening closed panes and tabs

[BrowserStore.swift](../Sources/Browse/BrowserStore.swift) keeps the last fifty pane or tab closures in one in-memory stack. Command-Shift-T reopens the most recent item and selects its original tab and workspace.

[BrowseApp.swift](../Sources/Browse/BrowseApp.swift) exposes Reopen Closed Pane or Tab in the File menu, disabled when the stack is empty. Closing the final pane records one whole-tab closure; extension-requested pane closures use the same history. Reopening clears zoom and the location popup. Closed views are released: restoration uses saved URLs and identities, without recovering page forms, scroll positions, or back-forward lists. Closed-item history is discarded on restart; reopened layouts are saved normally.

[Session.swift](../Sources/BrowseCore/Session.swift) restores the original split tree when the remaining layout is unchanged. Otherwise it inserts the closed pane beside the nearest surviving sibling, retaining subsequent splits, divider changes, and surviving page URLs. If no sibling remains, the pane opens beside the focused pane. Whole tabs return at their saved index. An unused blank tab created automatically after closing a workspace's last tab is removed on reopen; a replacement that has been navigated or split is retained.

## Pane layout animation

[PaneGeometry.swift](../Sources/BrowseCore/PaneGeometry.swift) resolves the split tree into flat pane and divider frames. [BrowserView.swift](../Sources/Browse/BrowserView.swift) keeps pane views keyed by page identity as their positions and sizes change.

Adding a pane animates existing frames over 180 ms with an ease-out curve. The new pane reveals horizontally for a right split or vertically for a lower split, without scaling its text or web content. The scroll view reveals the destination when it would extend beyond the viewport. Reduce Motion disables these layout and insertion animations.

The geometry retains pane minimum sizes and divider constraints, growing the scrollable canvas when necessary. Divider dragging updates immediately. Tab switches and session restoration start at their final layout; animation state is not persisted.

## WebKit integration

[BrowserStore.swift](../Sources/Browse/BrowserStore.swift) retains one WebKit controller per visited pane, keeping live pages and navigation history while switching tabs or changing layouts. The native host uses the system WebKit framework, not an embedded Safari application.

All panes share the app’s default persistent WebKit website data store, separate from Safari. Navigation updates the stored address and first-pane tab title. Command-clicking an HTTP or HTTPS link opens and focuses a new pane to the right of its source, leaving the source page unchanged and exiting pane zoom. This also applies to links targeting a new window; other new-window web links create tabs. Errors offer retry, and page JavaScript alert, confirm, and text-input dialogs use AppKit.

Command-click routing uses WebKit's navigation-action modifiers and left-button mask in both navigation policy and new-window callbacks. It cancels source navigation when opening a pane; plain clicks and non-link navigation retain their normal behavior.

Pane headers display full-color site favicons discovered from the completed document's icon links, then touch icons, then the origin's `/favicon.ico`. [FaviconLoader.swift](../Sources/Browse/FaviconLoader.swift) resolves and deduplicates candidates, bounds downloads, and uses an ephemeral cookie-free session with an in-memory HTTP cache. Missing or invalid icons use a site initial; internal pages retain their app symbols. Navigation clears the old icon and cancels pending work so stale results cannot replace the next page's icon.

External custom URL schemes are not handed to other applications. Downloads, website media permissions, native Safari App Extensions, and Safari session sharing are outside the implemented prototype. Safari Web Extensions use the separate [[architecture#Web extensions|Browse extension host]].

## Web extensions

[ExtensionManager.swift](../Sources/Browse/ExtensionManager.swift) hosts Safari Web Extensions through WebKit's public extension controller on macOS 15.4 and later, with enablement, permissions, and extension storage separate from Safari.

All extension packages, including Safari bundles, are copied into Browse's extension directory before validation and registration. WebKit reads ZIP, XPI, CRX, and unpacked resources. Imports start disabled. The extension list, original import location, declared package identity, approved permissions, and website patterns are saved atomically beside the session data. Each context keeps a stable identifier and extension origin across restarts. Existing externally referenced imports migrate to owned copies while retaining their identifiers and grants; migration failures leave the original record intact.

Manual replacement installs a separate package revision and retains the extension origin and storage. Replacement checks bundle identifiers, declared Gecko identifiers, or manifest keys when present; otherwise it requires the same display name. These checks identify user-selected local packages, not authenticated publisher updates. Invalid or mismatched replacements leave the installed version intact. Additional access keeps an update unloaded until approved. Package folders preserve internal relative symbolic links used by signed frameworks, but reject absolute or escaping links and special files. Removing an extension deletes its managed copy, never its original source.

Native messaging is left to WebKit's default app-extension handling; Browse implements no custom native messaging bridge. This does not establish companion-app compatibility: 1Password for Safari's native OS-version request fails with “Native messaging is not supported” in Browse. Its bundle can load, but unlock and autofill are not supported. Loading SafariServices does not resolve this failure.

[probe-native-extension.sh](../scripts/probe-native-extension.sh) builds a temporary, windowless diagnostic app that resolves a native extension through the Foundation API used by WebKit. It sends no native messages. The default runs without extra entitlements; setting `BROWSE_PROBE_HOST_ENTITLEMENT=1` signs only the probe with `com.apple.private.can-load-any-content-blocker`. On the tested Mac, PlugInKit rejects the default host for lacking that entitlement, while macOS kills the entitled probe before execution with “No matching profile found.” Browse's build does not claim this entitlement. See the [reproduction and limitations](../docs/extension-support-research.md).

Enabling an extension asks for its requested capabilities and website access. Updated extensions that need additional grants stay unloaded until reviewed. Runtime requests prompt separately and are granted for the current app session. Private website-data access is not granted. Unreadable extension metadata is preserved and prevents writes. Disabling unloads the extension; existing page changes disappear after reload. Removing also deletes the extension's Browse data and managed resource copy, leaving the source app and Safari settings intact.

[ExtensionBrowserBridge.swift](../Sources/Browse/ExtensionBrowserBridge.swift) maps every pane across workspaces to an extension tab and the browser window to an extension window. Focused panes are active tabs. The host reports creation, closure, focus, URL, title, and loading changes; tab queries do not instantiate unvisited web views. Web extensions can open web tabs, navigate, reload, activate, or close panes. The windows-create API, tab moves and grouping are not implemented.

[ExtensionDocument.swift](../Sources/Browse/ExtensionDocument.swift) hosts extension-owned pages, including options and extension-created tabs, in separate windows using their required context configuration. These windows and pages participate in the extension window/tab APIs and close when the owning extension is disabled or removed. External web links open in browser tabs.

[Extension tab updates](../Sources/Browse/ExtensionBrowserBridge.swift) can replace a website with the requesting loaded extension's own page, including a post-authentication confirmation page. [The page controller](../Sources/Browse/BrowserStore.swift) installs a context-configured web view while preserving pane and extension-tab identity. Returning to a website replaces it with an ordinary configuration; native back/forward history resets at this boundary. Saved extension panes wait for extension restoration before loading, and unavailable extensions show an error. Disabling or replacing an extension tears down its pane documents as well as separate windows.

[Navigation policy](../Sources/Browse/BrowserStore.swift) permits embedded pages from loaded extension contexts so inline extension menus can render and communicate with their background. WebKit still enforces web-accessible-resource declarations. Ordinary websites cannot promote themselves into privileged top-level extension documents.

Each browser web view receives the shared extension controller before creation. WebKit provides content scripts, background contexts, storage, and declarative request rules. The pane extension menu invokes actions with a user gesture; WebKit's popup is anchored to the associated visible pane. Availability of individual extension features depends on WebKit's API coverage and any native companion app's requirements.

Importing Chrome or Firefox resources does not establish full compatibility with those browsers. [[architecture#Extension compatibility adapters]] support Firefox 1Password onboarding without modifying its package. The user has confirmed vault items in its toolbar; authenticated inline autofill and desktop integration remain unverified.

## Extension compatibility adapters

[ExtensionCompatibility.swift](../Sources/Browse/ExtensionCompatibility.swift) adds basic notifications and main-frame navigation-target events to extension pages while preserving WebKit's native event delivery and permission checks.

The controller's extension-only web-view configuration injects the adapter at document start. The native `browser` namespace remains intact so WebKit can dispatch events; the `chrome` namespace forwards native APIs and supplies missing ones. The notification namespace is also exposed on `browser`. Ordinary website views receive no adapter, and native message handling rejects non-main frames, foreign origins, unloaded contexts, and missing notification permission. Extension source packages are not patched.

[ExtensionNotifications.swift](../Sources/Browse/ExtensionNotifications.swift) delivers basic macOS notifications, requests system authorization when a notification is created, and returns authorization failures to the extension. Notification IDs are scoped to the owning extension. Create, update, clear, enumeration, click, button, and dismissal callbacks are supported for the current session. Up to two buttons and bounded title/message lengths are accepted; richer notification types are rejected. Notifications use Browse's system icon and identify the extension in their title. Disabling, uninstalling, or replacing a context clears its tracked notifications and page registrations. Permission-level changes are checked on visibility changes and periodically while extension pages are alive.

[BrowserStore.swift](../Sources/Browse/BrowserStore.swift) records opener relationships for main-frame link openings before publishing the destination tab. [ExtensionBrowserBridge.swift](../Sources/Browse/ExtensionBrowserBridge.swift) exposes those relationships through WebKit. The adapter derives `chrome.webNavigation.onCreatedNavigationTarget` from real tab-created events, checking the current navigation permission and URL filters. Unrelated tab creation does not emit this event. Subframe source IDs are unavailable through this host's public navigation interface, so subframe openings are excluded rather than mislabeled. The native `browser.webNavigation` namespace is unchanged.

The [compatibility regression tests](../Tests/BrowseTests/ExtensionCompatibilityTests.swift) exercise native messaging alongside the adapter, notification scoping and revocation, rejection of website callers, cleanup, and navigation-event identity. The opt-in real-package test follows Firefox 1Password onboarding without entering credentials.

## Extension runtime diagnostics

[runtime.swift](../Tools/ExtensionProbe/runtime.swift) exercises real extension startup, actions, and extension-owned pages in a windowless app with temporary WebKit storage. It is separate from the production extension host.

The [runtime wrapper](../scripts/probe-extension-runtime.sh) signs a disposable app, enforces a bounded runtime, and removes its bundle on exit. The controller, background views, and test tab share an explicitly nonpersistent website data store. The diagnostic context grants private-data access only for that isolated store because WebKit otherwise filters its events. Browse's production permission policy remains unchanged. External tab requests fail explicitly; extension-owned tabs load invisibly. Diagnostics report page errors, selected console messages, action delivery, and rendered text without signing into an account.

The [Firefox 1Password reproduction](../scripts/probe-onepassword-firefox.sh) verifies a pinned Mozilla package checksum before extraction. Its baseline uses unmodified resources. The explicit diagnostic-startup mode guards one unsupported navigation listener in a temporary copy and injects [notification registration placeholders](../Tools/ExtensionProbe/startup-notifications.js); notification operations throw errors. This mode tests later startup stages, not API compatibility. It does not install or modify production packages. Research results and remaining limitations live in [extension-support-research.md](../docs/extension-support-research.md).

## Extension settings

[SettingsWindowController.swift](../Sources/Browse/SettingsWindowController.swift) provides Browse's own Settings window through Command-comma and pane extension menus. It manages web extensions without opening or modifying Safari preferences.

Settings opens to [[architecture#Curated extension catalog|Discover]], with an Installed view for managing packages, permissions, enablement, options, manual updates, and removal. Install from File accepts ZIP, XPI, CRX, or unpacked packages. A collapsed import section offers copies of Safari Web Extensions found in Applications. Updates are manual; automatic updates and general store browsing are not implemented. Load and runtime errors remain visible. Earlier macOS versions show the minimum version needed for extension support.

The enable switch reflects whether WebKit loaded the context, not whether every extension feature works. Settings identifies the Safari 1Password bundle and displays its known native-connection limitation. The Firefox package is marked experimental, with standalone sign-in instructions and an explicit desktop-integration and autofill limitation.

## Curated extension catalog

[ExtensionCatalog.swift](../Sources/Browse/ExtensionCatalog.swift) defines a bundled, curated collection with package-specific installation routes and explicit compatibility notes.

[ExtensionCatalogView.swift](../Sources/Browse/ExtensionCatalogView.swift) provides searchable cards, publisher and category information, source links, installation state, and Enable or Manage actions. uBlock Origin Lite's Safari package is labeled reported working; its local bundle is identified by bundle ID and copied into Browse. If absent, the card links to its official App Store listing. Returning to Browse or refreshing rescans Applications. Firefox 1Password is labeled experimental, with confirmed toolbar vault access and remaining autofill and desktop-unlock limitations. Safari 1Password is not offered as its catalog package.

The 1Password download is pinned to the reviewed Mozilla-hosted version and SHA-256. Downloads use an ephemeral session, a size limit and timeouts, require a successful HTTPS response, and validate the digest before import. [ExtensionManager.swift](../Sources/Browse/ExtensionManager.swift) checks the expected package identity before persistence, rejects duplicate identities, and cleans temporary downloads. Failed or cancelled downloads do not install a package. Catalog entries are matched to installed records by package identity, never display name. Imported packages remain disabled with no granted access until the user enables them and approves permissions. The catalog does not silently follow latest releases or update installed packages.

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
