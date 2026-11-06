# Architecture

Bend is a native macOS prototype combining SwiftUI browser chrome, AppKit windows, and system WebKit pages in nested tiling layouts.

## Development signing

[build-app.sh](../scripts/build-app.sh) packages and signs Bend.app, using `BEND_SIGNING_IDENTITY` when set and Yury's Apple Development certificate otherwise.

The package and executable product are named Bend. The bundle retains `dev.yury.browse.prototype`, the `BrowsePrototype` data directory, and existing window autosave keys so renaming does not create a separate profile. Internal Swift module names and `browse://` addresses remain stable. The legacy `BROWSE_SIGNING_IDENTITY` override is honored when the Bend override is unset.

The script enables Hardened Runtime and verifies the signature before reporting success and does not fall back to ad-hoc or self-signed signing. Apple-issued development or Developer ID signing uses a stable team partition for Keychain access; switching identities can still require one new approval. A self-signed identity supplied explicitly through the override does not prevent recurring WebCrypto prompts because macOS assigns it a per-build code-hash partition. The build does not alter Keychain access lists or key data.

Packaging creates a separate bundle in a temporary directory under `dist`, then signs and verifies it before replacing the installed bundle by rename. It does not overwrite the executable mapped by a running Bend process. Signing or verification failure leaves the previous build intact; publication failure restores the previous bundle. The script leaves Bend running and asks for a restart to use the new build. Extension packages, enablement, grants, and WebKit data remain outside the app bundle.

## Application icon

The app uses the supplied painted Bend artwork, with the untouched 2048×2048 source preserved in [BendIcon-original.jpg](../Assets/BendIcon-original.jpg).

The generated icon uses a top-aligned square crop that trims extra wall below and equally at the sides, vertically centering the B's main body rather than its trailing brush stroke.

[generate-app-icon.swift](../scripts/generate-app-icon.swift) renders the artwork with rounded corners, transparent margins, and a subtle shadow into standard and Retina icon sizes. Run `swift scripts/generate-app-icon.swift` on macOS to regenerate [AppIcon.png](../Assets/AppIcon.png) and [AppIcon.icns](../Assets/AppIcon.icns). [build-app.sh](../scripts/build-app.sh) copies the ICNS into bundle resources and sets the icon entry in Info.plist before signing.

## Application shell

[BrowseApp.swift](../Sources/Browse/BrowseApp.swift) owns menus, keyboard shortcuts, and application lifetime. [BrowserWindows.swift](../Sources/Browse/BrowserWindows.swift) owns the browser windows. [BrowserView.swift](../Sources/Browse/BrowserView.swift) renders a dark sidebar, vertical tabs, pane controls, and start pages.

The sidebar presents one continuous column of tabs without group headings or group creation. Each tab contains one or more browser panes. Selection changes the displayed tab; closing the final tab creates a replacement. The sidebar can be resized or hidden, with session-save errors shown at the bottom only when needed.

The sidebar header places a new-tab button beside a right-aligned sidebar toggle, without a brand label or a trailing new-tab row. Command-T and the File menu also create tabs. Panes use six-point outer margins and divider gaps, starting at the top window inset with no shared navigation bar. When the sidebar is hidden, the upper-left pane reserves space for window controls and exposes the sidebar toggle.

Each pane has one compact title row with extensions, reload/stop, split, zoom, and close controls, using shared [[architecture#Toolbar button styling]]. Reload focuses its pane and becomes stop while loading; it is disabled on start pages. The persistent address row is replaced by the [[architecture#Location popup]]. Back/forward remain available through the View menu and shortcuts; tab creation remains in the sidebar and File menu.

[BrowserWindows.swift](../Sources/Browse/BrowserWindows.swift) attaches an empty unified native toolbar to give the traffic lights standard toolbar-height spacing. AppKit manages their placement through resizing and full-screen transitions; the transparent titlebar has no separator or shared toolbar actions.

## Browser windows

[BrowserWindows.swift](../Sources/Browse/BrowserWindows.swift) owns independent native browser windows. File → New Window and Command-N create a blank tab in a new window with its address popup focused.

Each window owns its store, tab selection, pane controllers, sidebar sizing, zoom, closed-item stack, address panel, and saved frame. [BrowseApp.swift](../Sources/Browse/BrowseApp.swift) routes tab, pane, navigation, and history commands to the key browser window, falling back to the last active browser while a popup or Settings is key. Closing a window stops and releases only its page controllers. Pane and sidebar drag targets remain confined to their source window.

One retained root store owns history and UI preferences, including after its original window closes. Other [BrowserStore.swift](../Sources/Browse/BrowserStore.swift) instances delegate reads and writes to it and forward observation, so live history results and appearance changes reach every window. Settings and the extension manager are shared; normal website views use WebKit's shared default data store. [[architecture#Session restoration]] preserves each window's layout independently.

## Sidebar sizing

[SidebarResizing.swift](../Sources/Browse/SidebarResizing.swift) supplies an invisible eight-point handle at the sidebar's right edge, with a horizontal resize cursor and immediate resizing between 100 and 300 points.

Dragging measures pointer movement in window coordinates so resizing the sidebar cannot feed movement back into the gesture. [BrowserStore.swift](../Sources/Browse/BrowserStore.swift) clamps and saves the width in the session; older sessions default to 236 points. Hiding the sidebar preserves its width, and resizing retains live pane controllers. At narrow widths, header buttons move below the window controls and pane-count labels disappear to leave room for tab titles.

## Sidebar tab reordering

[TabReordering.swift](../Sources/Browse/TabReordering.swift) uses native sidebar drags to reorder or join tabs, with distinct insertion-line and whole-row previews.

A native mouse handle covers the tab label and starts dragging after five points of movement; ordinary clicks still select the tab, and close controls remain separate. A window-level surface shows a title badge and insertion line using the sidebar rows’ actual bounds. The middle 60% of a visible row joins tabs and shows a whole-row highlight plus a “Join tabs” badge. The top and bottom 20% select reorder boundaries; blank sidebar space after the last row remains an end-of-list target. Escape, window deactivation, source removal, or release outside all valid targets cancels without merging or changing order. The drag surface ignores hit testing, and retiring a SwiftUI handle explicitly clears its tracking and overlay. A fresh mouse-down cancels any unfinished gesture before reaching the newly clicked control. The event monitor forwards mouse-up to AppKit so repeated drags work. A completed move animates for 180 ms unless Reduce Motion is enabled.

Hovering a row’s join area for 400 ms selects the destination tab and clears zoom, retaining the original dragged tab. Moving into its visible canvas previews a merge above, below, left, or right of a chosen pane, using the same half-pane geometry as pane dragging. The whole source split tree occupies that half. Leaving the row cancels its pending timer; leaving a pane clears its preview. Cancellation after preview leaves the destination selected, matching pane dragging. Already-visible destination panes can be targeted directly; hidden panes, source-tab panes, zoomed canvas targets, stale sources, and other windows are rejected.

[BrowserStore.swift](../Sources/Browse/BrowserStore.swift) changes only the tab array for reordering and saves its order. Reordering leaves selection, pane layouts, zoom, live page controllers, and closed-item history unchanged. Self-drops, missing tabs, and already-adjacent placements are no-ops. Targets must belong to the source store and window; external pasteboard drags cannot reorder tabs. Joining removes the source tab and preserves its entire split tree. A direct sidebar drop places it to the right of the destination tree; a canvas drop replaces only the chosen destination leaf with an equal split along the selected edge, preserving unrelated branches and fractions. Internal split identities and fractions, page IDs, live controllers, and extension identities survive. The destination tab keeps its title, becomes selected, focuses the source’s focused pane, and exits zoom. No closed-item history is created; the combined layout is saved atomically. [[tests#Joining tab layouts]] covers model invariants and restoration. [[architecture#Pane drag and drop|Pane transfers]] use separate tracking and targets.

## Toolbar button styling

[ChromeButtonStyle.swift](../Sources/Browse/ChromeButtonStyle.swift) gives pane controls and the extension menu a shared appearance, with muted cool-gray icons and subtle white circular hover backgrounds shared with the pane title pill.

Pane controls use regular 12-point symbols on a 24-point pitch, with a 22-point hover circle. The title pill and controls are vertically centered in the full 36-point pane header; the bottom separator and loading strip overlay it without shifting the control row upward. Hover or pressing brightens the icon and reveals the shared white background at 6% opacity over 100 ms. Disabled controls stay dim and do not highlight. Sidebar header controls use a brighter 14-point symbol and a 28-point circle. Reduce Motion removes state-transition animations. The extension menu uses the button menu style so it receives the same sizing and interaction treatment as adjacent buttons. Native menu tracking clears cached hover when it begins and ends, preventing a missed mouse-exit event from leaving the extension button highlighted after dismissal.

## Sidebar materials

The sidebar and exposed workspace share one native Liquid Glass base on macOS 26 and later. Selected tabs retain their capsule-shaped glass selection. Earlier systems use standard AppKit and SwiftUI materials.

[BrowserWindows.swift](../Sources/Browse/BrowserWindows.swift) hosts each SwiftUI workspace inside [BrowserWindowGlass](../Sources/Browse/GlassAppearance.swift), which observes the persisted window style and tint without replacing its content view. AppKit manages the glass/content geometry together; the transparent window supplies the outer corner clipping. The base spans the sidebar, titlebar area, and gaps around panes, including when the sidebar is hidden. A separate background scrim controls its darkening without dimming foreground content.

[BrowserView.swift](../Sources/Browse/BrowserView.swift) omits the legacy sidebar and canvas backdrops on macOS 26 and later so they do not cover the shared glass. Earlier systems retain behind-window sidebar and under-window materials that follow the window's active state. Selection has no custom fill or border, and pane chrome retains its separate darkened material. Inactive tab hover adds a capsule filled with the shared 6% white button highlight and reveals a close button. The close-button space stays reserved to prevent title movement. Titles that exceed their available width fade to transparent over the trailing 24 points instead of showing an ellipsis; fitting titles remain fully visible. Hover fades over 100 ms, or changes immediately with Reduce Motion; selected tabs retain their glass selection.

## Pane materials

Browser panes use rounded native Liquid Glass panels on macOS 26 and later, with standard material on older systems. Focus uses a brighter title plus a configurable transparency, outline, or glow treatment.

[BrowserView.swift](../Sources/Browse/BrowserView.swift) uses Transparency by default: inactive panes, including chrome and page content, receive a configurable black overlay (8% by default). Outline and Outline glow instead mark the focused pane without dimming other panes. The outline has a color and 0.5–6 pt width, separated from the pane by one screen pixel (scaled for Retina). The pane is inset within its existing layout slot to leave room for the ring and gap, keeping thick outlines visible at canvas edges. Glow has a separate color, 0–100% intensity for opacity, and independent 0–24 pt spread for blur radius. [PaneHighlightOverlay.swift](../Sources/Browse/PaneHighlightOverlay.swift) draws outside the native pane clip so the glow reaches into the gutter. Decorations ignore hit testing and accessibility. Focus changes fade over 100 ms unless Reduce Motion is enabled. [[architecture#UI preferences]] owns these controls.

[BrowserView.swift](../Sources/Browse/BrowserView.swift) places the pane canvas over the shared [[architecture#Sidebar materials|app base material]]. Pane chrome and built-in pages reveal the panel material; web pages keep their own rendering. A narrow content inset sits behind an opaque neutral rim on the native clipping layer, covering bright glass bevels and page colors at the rounded edge. Pane body materials retain a 50% black scrim. Headers have their own configurable glass style, tint, and darkening, defaulting to Regular, no tint, and 50%. Their background sits beneath the controls; it does not dim text or web pages.

On macOS 26 and later, each live web page extends behind its compact title row. [WebSurfaceHost.swift](../Sources/Browse/WebSurfaceHost.swift) provides one native Liquid Glass surface behind the title and any open find controls; opening search extends that surface downward. Scrolling page colors show through while controls remain readable. The combined title and find height sets WebKit's obscured content inset, keeping fixed and sticky site elements below the controls. Start pages, errors, and older macOS versions retain the stacked header layout. Stacked headers and page bodies have separate backgrounds, so header customization does not alter built-in page bodies or apply darkening twice.

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

The geometry retains pane minimum sizes and divider constraints, growing the scrollable canvas when necessary. Dividers are invisible hit regions spanning the gaps; hovering shows the directional resize cursor, and dragging updates immediately. Drag translation uses a fixed global coordinate space so the moving divider does not feed its own movement back into the resize calculation. Tab switches and session restoration start at their final layout; animation state is not persisted.

## Pane drag and drop

[PaneDragging.swift](../Sources/Browse/PaneDragging.swift) provides title-bar dragging within and between tabs, with a floating title badge and blue previews for placing a pane above, below, left, or right of another pane.

Hovering the title highlights its favicon and text in a compact pill and crossfades the favicon to a four-way drag arrow over 100 ms; Reduce Motion makes the change immediate. Native tracking confines the hover treatment to the title pill. The title and adjacent empty header space have separate native drag handles and start an internal drag after a movement threshold; toolbar buttons keep their normal actions.

[BrowseWindow.swift](../Sources/Browse/BrowseWindow.swift) owns each gesture before AppKit can start native view tracking. Every press resolves a currently visible handle belonging to the selected tab. The window consumes the complete press/drag/release sequence, including motion after sidebar hover hides the source; pane handles install no event monitors. Its state is idle, tracking a source, or cancelled while awaiting release. Ownership clears before applying a drop. Cancellation keeps consuming the captured gesture through release, so AppKit never receives an orphan release. A fresh press resets ownership before finding its target; closing the window clears it entirely.

The temporary window-level badge and previews ignore hit testing. SwiftUI handle teardown explicitly cancels tracking even if AppKit still keeps the retired view mounted. Teardown, Escape, and window deactivation remove the badge and previews. Pointer positions are compared directly with visible pane rectangles, avoiding AppKit's pasteboard destination routing into WebKit.

[PaneDropEdge.swift](../Sources/BrowseCore/PaneDropEdge.swift) chooses the nearest normalized edge and its half-pane preview across the target's full visible content area. Previews stay visible while the pointer moves within a target. Only target changes clear the old highlight; edge or bounds changes update its path without hiding it. Leaving valid targets, cancelling, or completing a drag clears the preview. Self-drops, stale sources, and foreign windows are rejected. Pane-edge rearrangement is disabled while zoomed, but sidebar transfers remain available. External pasteboard drags do not initiate pane rearrangement.

Sidebar tab rows highlight during a drag; hovering for 400 ms selects the tab while retaining the original drag source. Newly mounted destination panes become targets immediately. Dropping directly on another tab atomically adds the pane to the right of its focused pane and selects it, including when the source is zoomed; dropping into empty sidebar space detaches it into a new tab at the end of the list. Dropping on the source tab is a no-op with no drop highlight. Successful sidebar transfers exit zoom. Leaving a row or cancelling clears the delayed selection and all previews.

[Session.swift](../Sources/BrowseCore/Session.swift) removes the source leaf, collapses its former split, and inserts the same pane beside the target with an equal split. Unrelated branches retain their identities and fractions. [BrowserStore.swift](../Sources/Browse/BrowserStore.swift) focuses the moved pane and saves the layout without closing pages or adding closed-item history. Same-tab moves retain mounted pane views and WebKit controllers. Cross-tab transfers preserve the page ID, live controller, navigation history, and extension tab identity. An emptied source tab is removed; an emptied workspace receives a blank tab. Transfers create no closed-item history and persist both layouts together. Moves animate over 180 ms unless Reduce Motion is enabled; divider dragging still updates immediately.

## WebKit integration

[BrowserStore.swift](../Sources/Browse/BrowserStore.swift) retains one WebKit controller per visited pane, keeping live pages and navigation history while switching tabs or changing layouts. The native host uses the system WebKit framework, not an embedded Safari application.

Selecting a visited tab does not load or reload its pages. Its [[architecture#Mounted tab views|mounted view hierarchy]] stays attached while inactive. First visits, reopened closed pages, and process restarts still load URLs.

Website configurations append Safari-compatible product tokens and a Bend identifier to WebKit’s default user agent before navigation, including when leaving extension pages. The Safari version comes from the installed app’s bundle metadata, with a macOS 14-era fallback; this prevents sites such as Google from serving legacy fixed-width layouts. This does not read Safari preferences or share its session.

All panes share the app’s default persistent WebKit website data store, separate from Safari. Navigation updates the stored address and first-pane tab title. Command-clicking an HTTP or HTTPS link opens and focuses a new pane to the right of its source by default, or a new tab when selected in [[architecture#UI preferences]], leaving the source page unchanged and exiting pane zoom. This also applies to links targeting a new window; other new-window web links create tabs. Errors offer retry, and page JavaScript alert, confirm, and text-input dialogs use AppKit.

Command-click routing uses WebKit's navigation-action modifiers and left-button mask in both navigation policy and new-window callbacks. It cancels source navigation when opening the destination; plain clicks and non-link navigation retain their normal behavior.

Pane headers display full-color site favicons discovered from the completed document's icon links, then touch icons, then the origin's `/favicon.ico`. [FaviconLoader.swift](../Sources/Browse/FaviconLoader.swift) resolves and deduplicates candidates, bounds downloads, and uses an ephemeral cookie-free session with an in-memory HTTP cache. Missing or invalid icons use a site initial; internal pages retain their app symbols. Navigation clears the old icon and cancels pending work so stale results cannot replace the next page's icon.

External custom URL schemes are not handed to other applications. Downloads, website media permissions, native Safari App Extensions, and Safari session sharing are outside the implemented prototype. Safari Web Extensions use the separate [[architecture#Web extensions|Bend extension host]].

## Native input diagnostics

[InputDiagnostics.swift](../Sources/Browse/InputDiagnostics.swift) provides opt-in, bounded native mouse tracing to distinguish window routing failures from events delivered to WebKit.

Settings’ Development tab controls input and pane logging, disabled by default. The preference persists in app defaults and applies immediately to both streams. Startup reads it before session restoration; disabling drains pending writes and stops recording while preserving existing files. Extension diagnostics remain separate.

Two JSONL streams share a run ID, monotonic sequence, timestamps, native view identities, and stable session pane UUIDs:

- `events.jsonl` records each left-button press, drag, and release at application monitoring, window dispatch, AppKit forwarding, web-view entry/return, pane handles, tab drag monitors, and sidebar resizing. The press pane remains the gesture owner through release even after hiding or reparenting; `receiverPaneID` separately identifies the receiving view or current hit target. Non-pane events have a null pane ID and explicit scope.
- `panes.jsonl` records model membership and transfers, pane and tab drag lifetimes/drop targets, hover selection, native attachment/detachment, frame changes, hiding/showing, retained tab root updates, zoom/focus, dividers, and programmatic canvas scrolling. It also records address panels, navigation decisions, command-click handling, web-view replacement/configuration, process exits, JavaScript dialogs, and extension activation, popovers, permission prompts, and focus requests. Tab IDs and related pane IDs identify relationships without conflating tabs with panes. Tab hover selection and canvas merge targets use the same lifecycle stream.

Pane UUIDs are assigned to web views before navigation and preserved across replacement. Native snapshots include window activation, drag ownership, first responder, hit-view ancestry, visibility, gesture-recognizer states, and extension-controller/user-script presence. Instrumentation does not consume or redispatch events; it observes our routing boundaries, not WebKit's internal DOM dispatch.

Both streams live in `~/Library/Application Support/BrowsePrototype/InputDiagnostics/`. Each independently rotates at 500 KiB, retaining a `.previous.jsonl` segment of the same maximum size (four files, at most about 2 MiB total). Oversized segments from older builds are discarded when that stream next writes. Separate serial background queues are capped at 64 pending records each; saturation rejects records without blocking input and reports its count in the next accepted record. Clean termination drains queued writes. Native snapshot identities use process-local hashes without retaining objects or registering weak references, so ancestor inspection remains safe during hosting-view destruction. Native addresses can be reused after destruction; pane UUIDs remain the durable identity. The gesture-owner map uses weak window keys only during live input dispatch. Records exclude coordinates, keyboard input, URLs, titles, and page content.

The hooks span [BrowseApp.swift](../Sources/Browse/BrowseApp.swift), [BrowseWindow.swift](../Sources/Browse/BrowseWindow.swift), [BrowserStore.swift](../Sources/Browse/BrowserStore.swift), [BrowserView.swift](../Sources/Browse/BrowserView.swift), [MountedTabContent.swift](../Sources/Browse/MountedTabContent.swift), [PaneDragging.swift](../Sources/Browse/PaneDragging.swift), [TabReordering.swift](../Sources/Browse/TabReordering.swift), [SidebarResizing.swift](../Sources/Browse/SidebarResizing.swift), [AddressPanelController.swift](../Sources/Browse/AddressPanelController.swift), and the extension bridge. [[tests#Input trace rotation]], [[tests#Independent input and pane log retention]], [[tests#Pane trace correlation]], [[tests#Input diagnostics during hosting teardown]], and [[tests#Input logging preference]] cover retention, attribution, destruction with logging active, and opt-in persistence.

## Web extensions

[ExtensionManager.swift](../Sources/Browse/ExtensionManager.swift) hosts Safari Web Extensions through WebKit's public extension controller on macOS 15.4 and later, with enablement, permissions, and extension storage separate from Safari.

All extension packages, including Safari bundles, are copied into Bend's extension directory before validation and registration. WebKit reads ZIP, XPI, CRX, and unpacked resources. Imports start disabled. The extension list, original import location, declared package identity, approved permissions, and website patterns are saved atomically beside the session data. Each context keeps a stable identifier and extension origin across restarts. Existing externally referenced imports migrate to owned copies while retaining their identifiers and grants; migration failures leave the original record intact.

Manual replacement installs a separate package revision and retains the extension origin and storage. Replacement checks bundle identifiers, declared Gecko identifiers, or manifest keys when present; otherwise it requires the same display name. These checks identify user-selected local packages, not authenticated publisher updates. Invalid or mismatched replacements leave the installed version intact. Additional access keeps an update unloaded until approved. Package folders preserve internal relative symbolic links used by signed frameworks, but reject absolute or escaping links and special files. Removing an extension deletes its managed copy, never its original source.

[[architecture#Native extension messaging]] connects Firefox packages to installed desktop helpers. Safari app-extension handlers remain unsupported: 1Password for Safari's bundle can load, but its native connection, unlock, and autofill do not work. Loading SafariServices does not resolve this failure.

[probe-native-extension.sh](../scripts/probe-native-extension.sh) builds a temporary, windowless diagnostic app that resolves a native extension through the Foundation API used by WebKit. It sends no native messages. The default runs without extra entitlements; setting `BROWSE_PROBE_HOST_ENTITLEMENT=1` signs only the probe with `com.apple.private.can-load-any-content-blocker`. On the tested Mac, PlugInKit rejects the default host for lacking that entitlement, while macOS kills the entitled probe before execution with “No matching profile found.” Bend's build does not claim this entitlement. See the [reproduction and limitations](../docs/extension-support-research.md).

Enabling an extension asks for its requested capabilities and website access. Updated extensions that need additional grants stay unloaded until reviewed. Runtime requests prompt separately and are granted for the current app session. Private website-data access is not granted. Unreadable extension metadata is preserved and prevents writes. Disabling unloads the extension; existing page changes disappear after reload. Removing also deletes the extension's Bend data and managed resource copy, leaving the source app and Safari settings intact.

[ExtensionBrowserBridge.swift](../Sources/Browse/ExtensionBrowserBridge.swift) maps panes from all registered browser stores to extension tabs, with an extension-window adapter for each native browser window. Each window has its own active pane. Tab queries, navigation, activation, closure, and explicit new-tab window requests use the owning store; activation brings that native window forward. Closing a window unregisters only its tabs and adapter. The single shared manager retains installed extensions and their background contexts. The host reports creation, closure, focus, URL, title, and loading changes; tab queries do not instantiate unvisited web views. Web extensions can open web tabs, navigate, reload, activate, or close panes. The windows-create API, tab moves and grouping are not implemented.

[ExtensionDocument.swift](../Sources/Browse/ExtensionDocument.swift) hosts extension-owned pages, including options and extension-created tabs, in separate windows using their required context configuration. These windows and pages participate in the extension window/tab APIs and close when the owning extension is disabled or removed.

Same-tab HTTP(S) navigation retains the document's tab identity and window. Because WebKit confines extension-configured views to their extension origin, the document retains that view and displays an ordinary website view during authentication. Returning through an authorized extension tab update reuses the original extension view and its session storage, preserving onboarding choices. The website view has no compatibility adapter or privileged extension APIs; its host appears in the window title. Websites cannot initiate a privileged return themselves. Links requesting a new window still open separate tabs or extension documents.

[Extension tab updates](../Sources/Browse/ExtensionBrowserBridge.swift) can replace a website with the requesting loaded extension's own page, including a post-authentication confirmation page. [The page controller](../Sources/Browse/BrowserStore.swift) installs a context-configured web view while preserving pane and extension-tab identity. Returning to a website replaces it with an ordinary configuration; native back/forward history resets at this boundary. Saved extension panes wait for extension restoration before loading, and unavailable extensions show an error. Disabling or replacing an extension tears down its pane documents as well as separate windows.

[Navigation policy](../Sources/Browse/BrowserStore.swift) permits embedded pages from loaded extension contexts so inline extension menus can render and communicate with their background. WebKit still enforces web-accessible-resource declarations. Ordinary websites cannot promote themselves into privileged top-level extension documents.

Each browser web view receives the shared extension controller before creation. WebKit provides content scripts, background contexts, storage, and declarative request rules. The pane extension menu invokes actions with a user gesture; WebKit's popup is anchored to the associated visible pane. Availability of individual extension features depends on WebKit's API coverage and any native companion app's requirements.

Importing Chrome or Firefox resources does not establish full compatibility with those browsers. [[architecture#Extension compatibility adapters]] support Firefox 1Password onboarding without modifying its package. The user has confirmed vault items in its toolbar; authenticated inline autofill and desktop integration remain unverified.

## Native extension messaging

[ExtensionNativeMessaging.swift](../Sources/Browse/ExtensionNativeMessaging.swift) bridges WebKit native-message delegates to Firefox-compatible desktop helpers without sharing Safari's extension state.

The host resolves user then system Mozilla NativeMessagingHosts manifests, validates names, stdio transport, executable paths, and the requesting Gecko ID against allowed_extensions. Only loaded, registered contexts with nativeMessaging permission can connect. Launch arguments contain the real manifest path and extension ID; Bend remains the parent application with its own signature.

Persistent ports and one-shot replies use length-prefixed UTF-8 JSON over pipes. Frames are limited to 1 MiB, queued writes to 4 MiB, and concurrent connections to sixteen per context. Reads handle fragmented frames without waiting for the pipe to fill. Invalid input, EOF, write failures, and one-shot timeouts close the session. Payloads and helper stderr are not logged. Disable, removal, replacement, port disconnection, and permission revocation tear down connections and terminate helpers.

The installed 1Password helper is discovered through its Firefox manifest. Desktop unlock requires a qualifying distribution signature and the Bend app to be added through 1Password Settings → Browser → Add Browser, plus desktop integration enabled in the extension. Bend does not alter the trusted-browser list or impersonate Firefox. The transport and real extension's connection request are tested. The installed helper rejects the current Apple Development build; authenticated desktop unlocking and Touch ID remain unverified. Safari's proprietary app-extension route is not implemented.

## Extension compatibility adapters

[ExtensionCompatibility.swift](../Sources/Browse/ExtensionCompatibility.swift) adds notifications, limited privacy settings, and main-frame navigation-target events while preserving WebKit's native event delivery and permission checks.

The controller's extension-only web-view configuration injects the adapter at document start. The native `browser` namespace remains intact so WebKit can dispatch events; the `chrome` namespace forwards native APIs and supplies missing ones. Notification and privacy namespaces are also exposed on `browser`. Ordinary website views receive no adapter, and native message handling rejects non-main frames, foreign origins, unloaded contexts, and missing operation-specific permission. Extension source packages are not patched.

The privacy adapter implements password saving and legacy/address/card autofill service settings using [ChromeSetting's API shape](https://developer.chrome.com/docs/extensions/reference/api/types). Bend has no built-in savers, so reads report false and not controllable, disabling and clearing succeed without changing preferences, and enabling is rejected. Promise and callback forms are supported, with callback errors scoped to `runtime.lastError`; unrelated privacy settings and private scopes are unsupported. Safari preferences are never changed. This prevents Firefox 1Password's saved-account startup path from throwing on its browser password-manager settings calls.

[ExtensionManager.swift](../Sources/Browse/ExtensionManager.swift) includes the declared privacy permission in approval and persisted grants because WebKit omits unsupported permissions from its requested-permission set. The adapter checks explicit grants, including expiry and revocation, rather than WebKit's unsupported-permission query. Existing installations without that grant require review before loading with the new capability.

[ExtensionNotifications.swift](../Sources/Browse/ExtensionNotifications.swift) delivers basic macOS notifications, requests system authorization when a notification is created, and returns authorization failures to the extension. Notification IDs are scoped to the owning extension. Create, update, clear, enumeration, click, button, and dismissal callbacks are supported for the current session. Up to two buttons and bounded title/message lengths are accepted; richer notification types are rejected. Notifications use Bend's system icon and identify the extension in their title. Disabling, uninstalling, or replacing a context clears its tracked notifications and page registrations. Permission-level changes are checked on visibility changes and periodically while extension pages are alive.

[BrowserStore.swift](../Sources/Browse/BrowserStore.swift) records opener relationships for main-frame link openings before publishing the destination tab. [ExtensionBrowserBridge.swift](../Sources/Browse/ExtensionBrowserBridge.swift) exposes those relationships through WebKit. The adapter derives `chrome.webNavigation.onCreatedNavigationTarget` from real tab-created events, checking the current navigation permission and URL filters. Unrelated tab creation does not emit this event. Subframe source IDs are unavailable through this host's public navigation interface, so subframe openings are excluded rather than mislabeled. The native `browser.webNavigation` namespace is unchanged.

The [compatibility regression tests](../Tests/BrowseTests/ExtensionCompatibilityTests.swift) exercise native messaging alongside the adapter, notification scoping and revocation, rejection of website callers, cleanup, and navigation-event identity. The opt-in real-package test follows Firefox 1Password onboarding without entering credentials.

## Extension diagnostic log

[ExtensionDiagnostics.swift](../Sources/Browse/ExtensionDiagnostics.swift) records bounded, structured extension lifecycle and desktop-transport metadata across browser restarts without recording account data or message contents.

Each host run and native connection has a correlation UUID. Events identify extension import, restoration, loading, disabling, updates, removal, storage persistence and origin consistency, native-host resolution, process launch/exit, first queued/supplied messages, and final message counts. Process exit status and sanitized error categories distinguish missing helpers, permission failures, framing errors, disconnects, and initialization failures. A launched helper does not establish authenticated desktop integration.

[ExtensionCompatibility.swift](../Sources/Browse/ExtensionCompatibility.swift) reports extension-page API availability and categorizes error/rejection events before crossing the native bridge. The host validates the finite category set, rejects website callers, and deduplicates error categories per extension/run. WebKit errors are reduced to known domains, numeric codes, and fixed categories; raw error strings, stacks, URLs, helper stderr, and native-message payloads are excluded from the log and export.

The log lives beside extension metadata as diagnostics.jsonl, with one rotated predecessor; each file is capped at 256 KiB and created with owner-only permissions. Writes happen when events occur so a later process can inspect startup and shutdown. Failed disk writes retain a bounded in-memory fallback and surface a Settings warning. [SettingsWindowController.swift](../Sources/Browse/SettingsWindowController.swift) offers Copy Diagnostics, including fresh context snapshots and up to a thousand recent events, plus current native-helper status. The export contains metadata from all installed extensions so reinstall-generated identities can be correlated.

## Extension WASM diagnostics

[ExtensionWasmDiagnostics.swift](../Sources/Browse/ExtensionWasmDiagnostics.swift) observes WASM resource fetches and asynchronous compilation/instantiation inside extension pages, distinguishing the original failure from later core-not-initialized errors.

The adapter observes only same-extension .wasm fetches and WebAssembly's asynchronous compile/instantiate methods. It forwards fulfillment values and rejection objects, never consumes response bodies, and does not supply a MIME workaround or retry. Observers add a promise continuation; they do not diagnose vendor initialization after instantiation completes. Each page emits at most 96 observations. The host validates finite metadata values and deduplicates identical observations per context/run before recording wasmOperation events in [[architecture#Extension diagnostic log]].

Metadata includes background versus other extension page, operation/stage, response type, success flag, MIME category, and classified failures such as MIME rejection, CSP, compilation, linking, and runtime traps. URLs, resource names, module contents, exports, stacks, and raw errors never cross the diagnostic bridge. [[tests#Firefox WASM process restart]] exercises fresh and restored account-free startup with separate test processes; authenticated startup and desktop unlock are outside its coverage.

## 1Password connection probe

[OnePasswordConnectionProbe.swift](../Sources/Browse/OnePasswordConnectionProbe.swift) provides a status-only diagnostic invocation under Bend's own signed identity and application path, without creating browser windows or opening the user profile.

Running the built Bend executable with --diagnose-1password launches the registered helper and requests native-autofill feature status. It does not request accounts, credentials, delegated sessions, or unlocking. The probe waits up to ten seconds and prints only response types and allowlisted protocol error names, exiting successfully only for a matching Success response. It does not change the desktop app's trust configuration.

The same summary is included in production nativeProtocolStatus events for 1Password connections. It exposes known protocol types/error names and bounded, validated browser bundle identities from browser_state, never Success contents, callback IDs, account fields, or arbitrary error prose. These events distinguish protocol rejection from a pipe failure.

The probe and Settings perform a certificate preflight against the Apple distribution-certificate requirement observed in the installed 1Password helper, and inspect the Hardened Runtime flag. The available Apple Development identity fails that requirement. Status-only probes report UnknownBrowser from dist and BrowserSignatureInvalid from an unchanged Applications copy; enabling Hardened Runtime alone leaves the signature rejection. Settings explains the certificate blocker rather than suggesting reinstalling. Developer ID signing can be selected through the existing build override, but its end-to-end desktop result is not yet verified. The preflight does not replace 1Password's own validation or change its trust settings.

## Extension runtime diagnostics

[runtime.swift](../Tools/ExtensionProbe/runtime.swift) exercises real extension startup, actions, and extension-owned pages in a windowless app with temporary WebKit storage. It is separate from the production extension host.

The [runtime wrapper](../scripts/probe-extension-runtime.sh) signs a disposable app, enforces a bounded runtime, and removes its bundle on exit. The controller, background views, and test tab share an explicitly nonpersistent website data store. The diagnostic context grants private-data access only for that isolated store because WebKit otherwise filters its events. Bend's production permission policy remains unchanged. External tab requests fail explicitly; extension-owned tabs load invisibly. Diagnostics report page errors, selected console messages, action delivery, and rendered text without signing into an account.

The [Firefox 1Password reproduction](../scripts/probe-onepassword-firefox.sh) verifies a pinned Mozilla package checksum before extraction. Its baseline uses unmodified resources. The explicit diagnostic-startup mode guards one unsupported navigation listener in a temporary copy and injects [notification registration placeholders](../Tools/ExtensionProbe/startup-notifications.js); notification operations throw errors. This mode tests later startup stages, not API compatibility. It does not install or modify production packages. Research results and remaining limitations live in [extension-support-research.md](../docs/extension-support-research.md).

## Extension settings

[SettingsWindowController.swift](../Sources/Browse/SettingsWindowController.swift) provides Bend's own Settings window through Command-comma and pane extension menus. It manages web extensions without opening or modifying Safari preferences.

Settings has Extensions, UI, and Development tabs. Development exposes the opt-in [[architecture#Native input diagnostics|input and pane logging]] toggle. Extensions shows only the three [[architecture#Curated extension catalog|curated packages]], with installation, enablement, permissions, options, diagnostics, manual updates, and removal in each card. There are no Discover/Installed subviews or general package-import controls. Updates are manual; automatic updates and general store browsing are not implemented. Load and runtime errors remain visible. Earlier macOS versions show the minimum version needed for extensions while keeping UI preferences available.

The enable switch reflects whether WebKit loaded the context, not whether every extension feature works. The curated Firefox 1Password package is marked experimental, with desktop trust-registration instructions and an explicit unverified Touch ID limitation.

## Curated extension catalog

[ExtensionCatalog.swift](../Sources/Browse/ExtensionCatalog.swift) defines a bundled, curated collection with package-specific installation routes and explicit compatibility notes.

[ExtensionCatalogView.swift](../Sources/Browse/ExtensionCatalogView.swift) provides three fixed cards with publisher and category information, source links, installation state, enable switches, and inline management controls. uBlock Origin Lite's Safari package is labeled reported working; its local bundle is identified by bundle ID and copied into Bend. If absent, the card links to its official App Store listing. Returning to Bend or refreshing rescans Applications. Firefox 1Password is labeled experimental, with confirmed toolbar vault access and remaining autofill and desktop-unlock limitations. Safari 1Password is not offered as its catalog package. Dark Reader is offered as an experimental Firefox package; dark styling and global and per-site toggles pass the isolated compatibility test.

The 1Password and Dark Reader downloads are pinned to reviewed Mozilla-hosted versions and SHA-256 digests. Downloads use an ephemeral session, a size limit and timeouts, require a successful HTTPS response, and validate the digest before import. [ExtensionManager.swift](../Sources/Browse/ExtensionManager.swift) checks the expected package identity before persistence, rejects duplicate identities, and cleans temporary downloads. Failed or cancelled downloads do not install a package. Catalog entries are matched to installed records by package identity, never display name. Imported packages remain disabled with no granted access until the user enables them and approves permissions. The catalog does not silently follow latest releases or update installed packages.

## UI preferences

[SettingsWindowController.swift](../Sources/Browse/SettingsWindowController.swift) opens Settings on the UI tab, with link-opening, active-pane highlighting, and independent window/header glass controls.

[BrowserStore.swift](../Sources/Browse/BrowserStore.swift) saves shared UI preferences in the root session file; secondary windows delegate to that store. Command-click offers a new pane to the right (the default), one dedicated pane per tab, or a new tab. Changes apply to existing controllers immediately. Older sessions preserve their previous new-pane/new-tab choice. Ordinary new-window links continue opening tabs. Main-frame opener tracking is preserved for all destinations.

In dedicated-pane mode, the first Command-click creates a pane to the right of its source. Later Command-clicks anywhere in that tab navigate and focus the same pane, retaining its WebView and navigation history. The pane identity persists in the tab across restarts. Closing or moving it away clears the designation; the next click creates a replacement. Reopening the closed pane restores its designation if no replacement exists. Joining tabs keeps the destination’s designated pane, or adopts the source’s when the destination has none. Clicking from the dedicated pane reuses itself without a self-opener; iframe links clear any previous main-frame opener. [[tests#Dedicated Command-click pane]] and [[tests#Command-click preference migration]] cover reuse and compatibility.

[PaneHighlight.swift](../Sources/BrowseCore/PaneHighlight.swift) persists the highlight mode, separate outline/glow colors, outline width, glow intensity, and glow spread. Older highlight records without spread retain their former intensity-derived radius. Transparency is the legacy-compatible default. Settings show only controls relevant to the selected mode; switching modes retains their values. Preferences are shared across windows and update mounted panes without replacing WebViews. Nonfinite values fall back to defaults and numeric values are bounded. [[tests#Mounted tab switching]] checks page hit testing in every style.

Inactive-pane dimming, available in Transparency mode, ranges from 0% to 100%, defaults to 8%, and updates all mounted panes immediately. Values are clamped and nonfinite edits are ignored. [Session.swift](../Sources/BrowseCore/Session.swift) stores optional fields so older session files retain their tabs and receive the original defaults. [[tests#UI preference persistence]] and [[tests#Configurable link destination]] cover persistence and routing.

On macOS 26 and later, Browser window and Pane headers each offer Regular/Clear style, optional custom sRGB tint, a 0–100% darkening slider, and an independent reset. Defaults preserve untinted Regular glass, with no window darkening and 50% header darkening. Changes apply live to every existing native browser window and mounted header. [GlassAppearance.swift](../Sources/BrowseCore/GlassAppearance.swift) stores each appearance in optional session fields and normalizes numeric values; older sessions keep their content and receive defaults. Blur and refraction remain system-controlled. [[tests#Live window glass preferences]] covers native updates without content replacement.

## Page zoom

[BrowseApp.swift](../Sources/Browse/BrowseApp.swift) routes page zoom shortcuts to the focused visible web pane in the active browser window, using WebKit's native page zoom.

Command-plus and Command-equals zoom in, Command-minus zooms out, and Command-zero resets to 100%. View menu actions use bounded steps from 25% to 500%, disabling at the limits. Start/history pages, errors, hidden panes, and unrelated key windows are excluded. Zoom affects page content without resizing browser chrome, reloading the document, or changing the separate Zoom Pane layout mode. Each live web view retains its own scale across navigation and tab switches; it is not persisted across app restarts. [[tests#Page zoom shortcuts]] covers keyboard routing and limits.

## Find in page

[WebSurfaceHost.swift](../Sources/Browse/WebSurfaceHost.swift) hosts a compact AppKit search bar per web pane, using WebKit's public find API for matching, selection, and scrolling.

On macOS 26 and later, the controls sit in a transparent row inside the title's shared native glass header. The header expands on opening and contracts on dismissal, using the same style, tint, and background-only darkening for both rows. Appearance updates retain the field editor and existing controls. Older systems use a separate standard-material row below the stacked title.

[BrowseApp.swift](../Sources/Browse/BrowseApp.swift) routes Command-F, Command-G, and Shift-Command-G to the focused pane of the active browser window, excluding other key windows. Internal start/history pages and error views disable these commands. The bar sits beneath the pane header and reserves page viewport space. Search is case-insensitive, updates while typing, wraps in both directions, and displays a native match total (including zero). Counts above the bounded search limit display “10,000+ matches.” Return and Shift-Return advance forwards and backwards; Escape or the close button dismisses the bar and returns focus to the page. Dismissal and empty queries clear the native find indicator and search selection without resetting scroll. Reopening with a retained query searches again; next/previous commands also reopen a hidden bar.

[BendFindSupport.m](../Sources/WebKitFindSupport/BendFindSupport.m) isolates optional private WebKit selectors in a typed Objective-C adapter: native match counting, clearing the find selection with an empty native search, and hiding find UI. Counting uses the same case-insensitive engine across frames, excludes non-searchable text, and caps work at 10,000 matches. Runtime selector checks preserve public search if SPI is unavailable; the total is omitted instead of guessed. Cleanup falls back to clearing document selections in the main and same-origin frames if native clearing is unavailable. This adapter requires compatibility checks when WebKit changes and is not a public-SDK-only implementation.

Each mounted pane retains its query and bar state. Navigation dismisses the bar; replacing its WebView invalidates pending results. Completion generations prevent stale search/count results from changing current status; count replies are paired with queued requests in query order. Replacement detaches the optional count delegate. Find actions and bar visibility enter optional pane diagnostics without recording the query. [[tests#Find in page]] covers search and keyboard routing.

Escape delivered to the web pane dismisses an open find bar. With no bar, cancellation is a no-op, including for detached views. Neither native view calls the optional superclass cancellation action, which has no implementation. WebKit still delivers Escape key events to page content.

The match count sits inside the search field, right-aligned before the native clear button. A custom search cell reserves trailing space for both drawn text and the field editor, even while results are pending. Monospaced digits keep counts stable; narrow fields limit the count area to preserve editable space.

Moving between matches for the same query keeps the count visible while refreshing it for possible page changes. Editing the query clears the previous total until the new result arrives; dismissal and empty queries also clear it.

## Mounted tab views

[MountedTabContent.swift](../Sources/Browse/MountedTabContent.swift) retains a native hosting view for each visited tab, hiding inactive containers instead of rebuilding the pane canvas on selection.

Unvisited tabs stay lazy. Inactive content remains natively hidden while its pane and WebKit parent views stay attached. The tab hosting view explicitly returns no hit when it or an ancestor is hidden, before entering SwiftUI hit testing: a hidden SwiftUI root can otherwise claim events intended for the visible page. Hidden containers retain their last viewport; selection applies the current size. Closed tabs release their containers, and closed panes are removed from retained trees. Focus moves out of a hidden canvas without taking focus from unrelated controls.

Tab and pane hosting views disable inherited safe-area regions: the window shell supplies their margins, so the unified titlebar must not insert extra space above nested content.

[BrowserView.swift](../Sources/Browse/BrowserView.swift) renders each retained canvas from its own tab model. Pane focus and window controls belong to that tab, and another tab's zoom cannot replace its layout. A cross-tab pane transfer reattaches the existing web view to the destination host without navigating or replacing its controller. Retention avoids reparenting and zero-sized WebKit layout during ordinary tab switches; it does not prevent WebKit process termination or pages' own background behavior. [[tests#Mounted tab switching]] verifies native parent identity and document state.

## Session restoration

[BrowserStore.swift](../Sources/Browse/BrowserStore.swift) debounces atomic JSON saves to the app’s Application Support directory and saves on normal termination. [Session.swift](../Sources/BrowseCore/Session.swift) checks restored tab, focus, and pane identity consistency before accepting state.

[BrowserWindows.swift](../Sources/Browse/BrowserWindows.swift) saves the open window IDs in `windows.json`. The legacy primary layout and shared preferences remain in `session.json`; additional windows save separate `Windows/<UUID>.json` sessions. With no window manifest, startup restores the legacy window. Normal quit saves the whole open set before native teardown. Closing one of several windows removes it from the manifest; closing the final window retains it for the next launch. [[tests#Browser window restoration]] covers both paths.

Persistence retains the workspace envelope for compatibility, plus selected tab, URLs, focused panes, and split trees. On load, [BrowserStore.swift](../Sources/Browse/BrowserStore.swift) combines legacy workspaces into one in their existing tab order, preserving tab and pane identities, layouts, URLs, and selection. New sessions start with one workspace; group names are not displayed. Restarting recreates web views from URLs; in-page state and back-forward lists are only retained during the running process. Invalid session files fall back to the initial workspace. Save failures appear in the sidebar.

## Browsing history

[History.swift](../Sources/BrowseCore/History.swift) models a bounded, serializable collection of web visits. It normalizes HTTP and HTTPS addresses, strips embedded credentials, and combines rapid consecutive visits to the same URL.

Visits retain titles and timestamps, newest first, up to 10,000 visits. Consecutive visits to the same URL within 30 seconds coalesce. Removing a URL also removes its learned suggestion choices; clearing history removes both visits and choices.

[BrowserStore.swift](../Sources/Browse/BrowserStore.swift) records successful web navigations. Later URL changes on a completed, idle page create visits, while title changes update the latest matching visit. Internal pages and failed navigations are excluded.

[BrowserStore.swift](../Sources/Browse/BrowserStore.swift) persists visits and learned choices atomically in one root history file shared across windows. Secondary stores forward history writes and observations to the root owner, avoiding conflicting snapshots. Writes are debounced and flushed with session saves; removal and clearing save immediately. An unreadable history file is preserved until an explicit clear permits replacement, with errors exposed by the store.

## History interface

[HistoryView.swift](../Sources/Browse/HistoryView.swift) displays searchable visits grouped by local calendar day in the built-in history page, with controls to revisit or remove pages and clear recorded history.

The History menu and Command-Y open `browse://history`, reusing an existing history pane across workspaces when available. Selecting a visit navigates the current pane; its context menu can open a new tab. Removing a page deletes all visits and learned choices for that URL. Clearing all history requires confirmation and leaves open pages and website data intact. The view displays history read and write errors from the store.

## History suggestions

[History.swift](../Sources/BrowseCore/History.swift) groups visits by URL and ranks matching suggestions using prior choices, URL match strength, and visit frequency weighted by recency.

Matching ignores case and diacritics and requires every query word to occur in the title or decoded URL. URL-prefix completions preserve the typed prefix; whitespace-containing queries do not receive inline completions.

Suggestions combine visits into one result per URL. Ranking prefers URL match strength, with visited home pages ahead of deep links for host-prefix queries, then frequency with a 30-day recency half-life plus a bounded learned-choice bonus. A single previous choice cannot permanently outrank repeated visits; path queries still find matching deep links. Learned choices are bounded to 1,000 query/URL pairs and decay over time. Matching runs locally without sending partial queries to a search engine or preloading pages.

The interaction draws on [Firefox's address-bar matching](https://support.mozilla.org/en-US/kb/address-bar-autocomplete-firefox), its [frequency/recency and adaptive-input ranking](https://firefox-source-docs.mozilla.org/browser/urlbar/ranking.html), and [Safari's combined search field](https://support.apple.com/en-ie/guide/safari/sfrid73436cb/mac). Bend implements its own bounded ranking over recorded visits.

[AddressPanelController.swift](../Sources/Browse/AddressPanelController.swift) combines history matches with a direct visit or search action in the [[architecture#Location popup]]. The popup refreshes when history changes; selecting a history result records the typed query to influence later rankings.

## Address handling

[Session.swift](../Sources/BrowseCore/Session.swift) resolves web addresses, localhost development URLs, built-in start pages, and search queries. Explicit non-web schemes are rejected; search text is encoded as a Google query parameter.

Bare hostnames containing dots use HTTPS, while localhost and loopback IPv4 addresses use HTTP. [BrowserStore.swift](../Sources/Browse/BrowserStore.swift) also limits WebKit navigation to web URLs and internal blank documents.

## Location popup

[AddressPanelController.swift](../Sources/Browse/AddressPanelController.swift) owns a floating, Spotlight-style native location panel. URL entry is separate from pane chrome. Its empty hint uses explicit light-gray text for contrast against the dark material.

Command-L and the start-page location button open the popup for a specific pane, with its current URL selected (blank for start pages). Return navigates that pane using the [[architecture#Address handling|address resolver]]; invalid input stays open with an error that clears when editing resumes.

[AddressPanelController.swift](../Sources/Browse/AddressPanelController.swift) displays [[architecture#History suggestions]] beneath the input. Arrow keys select results, Return opens the selection, and clicking a result opens it. Eligible URL prefixes autocomplete with the added suffix selected; deletion, marked text input, and edits away from the end suppress autofill.

Opening the popup shows frequent/recent pages while retaining the current address selected for editing. Typing shows up to six history matches alongside an explicit visit/search action. Inline URL matches become the selected top result; other queries keep the explicit action selected. History updates preserve selection when possible. Each history row has a Remove from history button that deletes all visits and learned choices for its URL, saves immediately, and removes stale suggestions without navigating or closing the popup. Results sit directly beneath the input with compact spacing; validation errors reserve extra space only while visible.

The popup is a borderless child panel positioned near the main window's upper center. It uses native HUD material with a 50% black background scrim, accepts keyboard focus without becoming the main window, supports full-screen use, and hides when the app deactivates.

A stretchable rounded material mask shapes both the backdrop and the native window shadow. The dark scrim uses the same corner radius, keeping it inside the material's outline as the popup width changes.

Selected suggestions use a rounded native clear-glass background on macOS 26 and later, with a subtle translucent fill on earlier systems. The selection keeps the compact row alignment and leaves keyboard focus in the address input.

Escape dismisses an existing tab’s popup and returns keyboard focus to the browser, as does successful submission. During a new blank tab’s initial address entry, Escape or Command-W discards both the popup and that tab, restores the preceding tab and zoom, and adds nothing to closed-item history. Typed but unsubmitted text still counts as initial entry. Successful submission or outside dismissal commits the tab; opening its popup again does not make it disposable. Split panes, new-window initial tabs, and last-tab replacements are retained. [[tests#Canceling new tab entry]] and [[tests#New tab popup keyboard cancellation]] cover the boundaries. Losing key-window status dismisses it without reclaiming focus, allowing outside clicks to select another pane or application normally.

[BrowserStore.swift](../Sources/Browse/BrowserStore.swift) requests the popup after creating blank split panes, tabs, or a replacement for the last closed tab. Link-created panes and tabs already have a destination and do not prompt. Popup requests validate pane identity; submitting after the target has closed or left the selected tab cannot navigate another pane.

[BrowserWindows.swift](../Sources/Browse/BrowserWindows.swift) connects each store's location-request callback to the panel controller. Requests carry a pane identity after the store has updated selection and focus, so presentation does not depend on a newly created SwiftUI pane observing an earlier event.
