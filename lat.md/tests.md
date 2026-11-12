---
lat:
  require-code-mention: true
---
# Tests

Model, store, and navigation-delegate tests cover pane layouts, persistence, link routing, navigation resolution, and location-popup requests without loading external websites.

Run the test suite and documentation validation from the repository root:

```sh
./scripts/test.sh
lat check
```

[[scripts/test.sh]] uses the installed SDK's version in the linked binary, matching the app and CI. Plain SwiftPM linking can select older AppKit compatibility behavior, including different sidebar constraints. With no arguments, [[scripts/test-all.py]] discovers the full inventory, runs core tests together, and runs each native test in a fresh process. This isolates AppKit's global menus, focus, and animation workers; accumulated native animations can exhaust dispatch workers in a long-lived test host. Every discovered test must report a result or its declared skip, and failed or timed-out processes fail the run. A crashed process, missing result, or unmatched filter is recorded as a failure while all later groups still execute; the final summary lists every failed group. Arguments such as `--filter` run a focused selection directly.

## Nested splits and closing

Splitting right and then below preserves leaf order. Closing panes collapses their parent branches, repairs focused-pane identity, and preserves the model’s final pane for the application layer to handle.

## Favicon discovery

[FaviconTests.swift](../Tests/BrowseTests/FaviconTests.swift) verifies relative icon URLs, deduplication, origin fallback, rejected URL schemes, and internal-page exclusion. A local WebKit document checks base URLs and standard icons taking priority over touch icons.

## Curated extension settings pages

[[Tests/BrowseTests/ExtensionTests.swift#curatedExtensionSettingsPages]] verifies settings routes for 1Password and Dark Reader without options declarations, declared-page precedence, identity isolation, enablement, native storage, window reuse, and cleanup.

## Curated extension settings smoke test

[[Tests/BrowseTests/ExtensionTests.swift#curatedExtensionSettingsSmoke]] optionally imports official 1Password and Dark Reader packages into disposable storage and verifies that their settings routes render controls without a manifest options declaration.

Set `BROWSE_TEST_FIREFOX_PACKAGE` and/or `BROWSE_TEST_DARK_READER_PACKAGE` to local package paths. The test enters no credentials and does not use existing extension storage.

## Extension lifecycle and permissions

[ExtensionTests.swift](../Tests/BrowseTests/ExtensionTests.swift) verifies disabled imports, permission denial and approval, website scope, copied resources, enable/disable behavior, and stable extension identity and grants after restoration.

## Enabled extension restoration

[ExtensionTests.swift](../Tests/BrowseTests/ExtensionTests.swift) recreates the extension host with an isolated persistent profile, verifying enabled state, stable origin, restored grants, and successive storage writes without the original package source.

The fixture unloads runtime contexts without disabling the saved preference. Four iterations read the previous iteration's extension storage, localStorage, and IndexedDB values, including decrypting a fixture ciphertext with a persisted nonextractable WebCrypto key. This exercises host recreation within one test process, not a signed-app upgrade or an authenticated password-manager session.

## Extension startup content injection

[[Tests/BrowseTests/ExtensionTests.swift#extensionStartupContentInjection]] starts navigation during extension restoration and verifies content-script injection across four host recreations.

WebKit compiles request rules asynchronously after context loading. The test awaits an explicit fixture ruleset update before checking blocking on a fresh navigation and before unloading the context. It does not claim first-navigation request blocking.

## Firefox extension restoration smoke test

[ExtensionTests.swift](../Tests/BrowseTests/ExtensionTests.swift) optionally exercises Firefox 1Password from `BROWSE_TEST_FIREFOX_PACKAGE`, checking enablement, origin, background loading, and toolbar actions across three host recreations in isolated storage.

The smoke test waits for background errors, invokes the toolbar action, and verifies that the resulting document renders 1Password's welcome page. It uses a fake notification provider and does not display windows, sign in, read a real vault, or verify authenticated autofill. Host recreation within one process is not a signed-app upgrade test.

## Media session commands and metadata

[MediaPlayerTests.swift](../Tests/BrowseTests/MediaPlayerTests.swift) checks document-start action capture, controls, title/artist extraction, metadata mutation, handler removal, native validation, command timeout, and stale-command rejection after navigation.

## Media playback progress

[MediaPlayerTests.swift](../Tests/BrowseTests/MediaPlayerTests.swift) verifies Media Session timing, native interpolation, pause freezing, seek-handler arguments, clearing position state, and rejection of invalid durations and seek targets.

HTML fallback fixtures also verify duration and seeking for attached and detached audio. The optional sidebar snapshots include a seekable progress bar at narrow and regular sidebar widths.

## Media progress layout

[MediaPlayerTests.swift](../Tests/BrowseTests/MediaPlayerTests.swift) verifies the card height and progress-bar frame stay unchanged as timing appears, disappears between tracks, and returns with a new duration. Missing timing disables seeking.

Live bottom-rim clipping changes from zero through fractional to maximum values preserve the card height and progress-bar frame.

## Media slider interaction

[MediaPlayerTests.swift](../Tests/BrowseTests/MediaPlayerTests.swift) verifies the styled native slider commits keyboard and accessibility changes immediately in five-second steps. The optional sidebar snapshots verify the track appearance at narrow and regular widths.

## Media frame routing and lifecycle

[MediaPlayerTests.swift](../Tests/BrowseTests/MediaPlayerTests.swift) targets an opaque-origin embedded player while another WebView shares its content controller, verifying frame and pane isolation, removal cleanup, and process-termination invalidation.

## HTML media fallback controls

[MediaPlayerTests.swift](../Tests/BrowseTests/MediaPlayerTests.swift) plays a silent WAV in an open shadow root and in off-DOM audio elements, verifying discovery, commands, exclusive playback, and cleanup.

Both `new Audio()` and `document.createElement` fixtures work without DOM insertion or declared Media Session playback state. Play/pause controls, page-title fallback, and resuming work in all cases; volume commands are rejected without changing page volume; removing and emptying the player retires it.

## Sidebar media ownership

[MediaPlayerTests.swift](../Tests/BrowseTests/MediaPlayerTests.swift) verifies commands reach a background tab, title activation reveals its pane, cross-window transfer retains the live WebView, dismissal survives refresh, resumed playback restores the card, and closure removes it.

## Media track transitions

[MediaPlayerTests.swift](../Tests/BrowseTests/MediaPlayerTests.swift) verifies that pauses and brief inactive sessions between tracks preserve the selected source, while real stops expire and navigation clears it immediately.

## Media source menu images

[MediaPlayerTests.swift](../Tests/BrowseTests/MediaPlayerTests.swift) verifies native player menu rows include correctly sized favicon and fallback images, explicitly visible images on macOS 27, selected state, and actions bound to their source.

The test and application compile with the macOS 26 SDK using SDK-independent property access; no newer enum or property declaration is referenced.

## Media source selection

[MediaPlayerTests.swift](../Tests/BrowseTests/MediaPlayerTests.swift) checks most-recent playback selection, explicit source selection, commands affecting only that source, persistent dismissal, reappearance on new playback, and cleanup on native-page navigation.

Sources are ordered most-recent-first after playback starts and explicit selection; refreshes, pauses, and metadata changes do not reorder them. With two sources, closing hides the entire panel while retaining both players and their playback state. Refreshing either source or changing metadata keeps it hidden; a new playback start reveals the panel with both players still available.

## Exclusive media playback

[MediaPlayerTests.swift](../Tests/BrowseTests/MediaPlayerTests.swift) starts media in competing panes and windows, checks that older players pause, resumes an older source, and rejects a queued pause for its previous playback revision.

Stopping the new owner must leave older players paused. The HTML fallback fixture separately checks the underlying audio element is paused when another pane starts.

## Short media filtering

[[Tests/BrowseTests/MediaDurationTests.swift#shortMediaFiltering]] plays real audio/video notifications at one and seven seconds, verifying no transient card, no interruption of another pane, and immediate controls above the cutoff.

A short sound in the same frame must preserve the longer player's identity and duration. Looping does not turn a short clip into eligible long media.

## Unknown media duration qualification

[[Tests/BrowseTests/MediaDurationTests.swift#unknownMediaDurationQualification]] verifies unknown and infinite-duration sessions stay hidden until seven seconds of playback, exclude paused time, and become visible through a native deadline without idle polling.

A later known short duration removes an already qualified source, while a duration just above seven seconds restores controls immediately.

## Media qualification lifecycle

[[Tests/BrowseTests/MediaDurationTests.swift#mediaQualificationLifecycle]] uses a controlled HTML playback clock to exclude paused and buffering time, reset eligibility on resource replacement, and preserve qualified controls when timing disappears.

## Persistent favicon restoration

[[Tests/BrowseTests/FaviconTests.swift#persistentFaviconRestoration]] loads a real favicon, restores a saved profile, and renders both stacked icons without creating pane controllers; a live pane starts with its cached icon and refreshes it through WebKit.

Regular windows share the cache while separate profiles do not. Private panes cannot read regular icons, and successful private icon loads, history clearing, and teardown leave the regular cache unchanged and create no private files. Clearing regular history removes persisted icons.

## Favicon cache bounds and recovery

[[Tests/BrowseTests/FaviconTests.swift#faviconCacheBoundsAndRecovery]] checks cached pixel colors, origin normalization without URL secrets, scheme/host/port isolation, oldest-entry eviction, corrupt snapshots and image rejection, and usable in-memory icons after write failures.

## Stacked favicon transitions

[[Tests/BrowseTests/FaviconTests.swift#stackedFaviconTransitions]] verifies insertion and focus swaps fade changed icons, while initial mounting, unchanged updates, Reduce Motion, and returning to one pane leave no unwanted animations.

## Sidebar favicons

[FaviconTests.swift](../Tests/BrowseTests/FaviconTests.swift) loads an icon through a local HTTP fixture and checks the mounted sidebar image updates to that exact favicon, resets for a native page, and leaves unvisited tabs uninstantiated.

Mounted front images remain 16×16 points and rear images 12×12 points in a fixed 24×28-point slot across sidebar widths. A three-pane tab renders exactly two horizontally centered icons with their combined bounds vertically centered in the slot, updates the front icon on focus changes, and keeps number labels out of the icon stack. Rendered pixels must darken toward the front icon’s overlap, verifying the contact shadow is visible. Closing panes updates the rear icon and pane count, then hides the rear icon for a single pane. Opaque oversized rasters exercise clipping; `BEND_SIDEBAR_SNAPSHOT` optionally captures the stack for visual inspection.

## Live media session smoke test

[MediaPlayerTests.swift](../Tests/BrowseTests/MediaPlayerTests.swift) optionally loads `BEND_MEDIA_SMOKE_URL` in an ephemeral WebKit store, attempts muted playback, matches the sidebar title to Media Session metadata, and tests pause/resume with default playback policy.

This opt-in check uses no saved sign-in and depends on the site's availability, consent flow, and playback policies. Local fixtures cover the deterministic bridge behavior. `BEND_MEDIA_SNAPSHOT` optionally renders the card with multiple players, a long title, and favicon at narrow, default, and wide sidebar widths, plus the full browser window, during the ownership fixture to inspect centered metadata, the compact favicon picker beside transport controls (with a separate row at minimum width), truncation, glass chrome, and pane spacing.

## Floating sidebar interaction

[FloatingSidebarTests.swift](../Tests/BrowseTests/FloatingSidebarTests.swift) exercises edge reveal, hover retention, delayed dismissal, tab selection through native hit testing, pinning, fullscreen edge geometry, and deactivation.

The same native interaction checks run on both window edges, including overlay hit routing and traffic-light access.

The mounted-window test verifies the canvas frame and retained WebView identities remain unchanged while the panel opens, switches tabs, and closes. The panel reaches the top inset behind the traffic lights, which remain native hit targets. The top-row pin button receives clicks above the pane header; covered pane headers cannot begin a pane drag. Exit and reentry are delivered in one main-actor turn before awaiting the dismissal interval, so cancellation does not depend on the runner resuming a short sleep before the deadline.

## Build bundle publication

[test-build-app.sh](../scripts/test-build-app.sh) runs the packaging script with isolated compiler and signing stand-ins, verifying failure preservation and replacement without changing an open descriptor to the previous executable.

Signing and verification failures retain the previous bundle and executable inode. Successful publication installs a new inode and removes staging files. The test checks VERSION and BEND_BUILD_NUMBER propagation into both profiles, invalid metadata rejection without replacing an existing bundle, the macOS 26 minimum in both profiles and the linker arguments, Debug’s distinct name, identifier, compiler configuration, and profile marker, production’s explicit Release flag and retained identifier, publication without touching the other channel, the icon resource and plist entry, HTTP/HTTPS URL-handler and HTML/XHTML document-viewer declarations, and precedence of the new signing override over the legacy override. These checks do not exercise macOS signing or WebKit runtime behavior.

## Production installer publication

[test-build-prod.sh](../scripts/test-build-prod.sh) exercises the production script with isolated native-tool stand-ins, checking notarization, ticket validation, packaging order, and failure-safe publication.

App or DMG rejection, headless packaging failure, invalid tickets, and disk-image verification failure retain the previous installer and detach temporary mounts. Successful publication requires the app ticket before packaging and the DMG ticket before final assessment. Failures retain their notarization logs; success removes only its own log folder while preserving earlier failure logs. The development app remains untouched by production compilation, packaging, and stapling; the production script must explicitly request its profile and output path. These tests do not substitute for Apple's real service or native disk-image layout verification.

## Catalog download integrity and identity

[ExtensionTests.swift](../Tests/BrowseTests/ExtensionTests.swift) rejects modified, empty, oversized, non-HTTPS, or unsuccessful catalog downloads and mismatched package identities before installation.

A rejected package leaves no installed record or package files. A matching import starts disabled without permission grants; unrelated package identities do not match curated entries.

## Catalog package download smoke test

[ExtensionTests.swift](../Tests/BrowseTests/ExtensionTests.swift) optionally downloads the pinned official 1Password and Dark Reader packages, validates their checksums, and imports each disabled into temporary storage.

Set `BROWSE_TEST_CATALOG_DOWNLOAD=1` to exercise the real catalog network path. The test verifies package identity and version without enabling the extension, opening windows, or touching the user's profile.

## Safari uBlock Lite compatibility

[[Tests/BrowseTests/UBlockLiteTests.swift#safariUBlockLiteSmoke]] probes the unmodified Safari uBlock Origin Lite package in an isolated Bend host with temporary extension and website storage.

Set `BROWSE_TEST_UBLOCK_SAFARI_PACKAGE` to the Safari extension bundle or official Safari ZIP. The package must report Safari from its own browser-detection module in both its live background page and popup, resolve real resource URLs on that origin, and select the Safari-specific disabled strict-blocking default. Diagnostic-only background-view access reads the loaded modules and logs their values. The probe verifies its identity, starts its background, tests an EasyList-matched script against a local HTTP fixture, and clicks the popup’s site filtering controls to turn blocking off and back on, then checks extension disable/re-enable behavior. A baseline verifies the script runs without the extension. The probe never changes the user's installed extensions.

## uBlock origin migration and isolation

[[Tests/BrowseTests/ExtensionTests.swift#uBlockOriginMigrationAndIsolation]] checks that uBlock Lite receives a Safari-style origin while preserving saved extension settings and keeping unrelated packages on their original scheme.

The test uses a Safari extension bundle fixture to seed native extension storage under the old origin, restores the same installed record, and verifies settings, UUID, enablement, compatibility-bridge access, and a saved page URL including its query. A lookalike display name with another package identity does not opt into the override. The opt-in [[tests#Safari uBlock Lite compatibility]] test verifies the real Safari package's browser detector, popup controls, and request blocking.

## Extension content injection and blocking

[ExtensionTests.swift](../Tests/BrowseTests/ExtensionTests.swift) loads a local HTTP fixture in real WebKit, verifies content injection and declarative blocking, then checks both disappear after disable/reload. It also verifies pane registration and active-tab changes.

## Extension compatibility permissions and notifications

[ExtensionCompatibilityTests.swift](../Tests/BrowseTests/ExtensionCompatibilityTests.swift) verifies WebKit extension messaging survives the adapters, notification IDs are isolated, callbacks report errors, permission revocation is enforced, and websites cannot call the bridge.

An injected notification backend exercises create, enumeration, click routing, clear, and disable cleanup without displaying system notifications or changing system authorization. The fixture uses its own ephemeral website data store.

## Extension created navigation events

[ExtensionCompatibilityTests.swift](../Tests/BrowseTests/ExtensionCompatibilityTests.swift) verifies a main-frame link opening emits a navigation-target event with the real WebKit tab ID while native tab events still arrive.

Unrelated tab creation and subframe openings do not produce a fabricated main-frame event. URL filtering is exercised with the fixture destination.

## Embedded extension pages and tab transitions

[ExtensionCompatibilityTests.swift](../Tests/BrowseTests/ExtensionCompatibilityTests.swift) verifies embedded extension messaging and website-to-extension tab updates with local, account-free fixtures.

A declared web-accessible iframe communicates with its background, while a private resource cannot run in the website. Website-initiated top-level extension navigation is rejected. An extension's tab update loads its own document with the same tab identity; a saved pane restores after its extension loads. Disabling tears down that document, and following a web URL returns to an ordinary view without privileged extension APIs.

## Extension WASM diagnostic behavior

[ExtensionCompatibilityTests.swift](../Tests/BrowseTests/ExtensionCompatibilityTests.swift) checks real WASM MIME rejection, ArrayBuffer fallback, invalid-module errors, observer failure isolation, and redaction in an isolated WebKit extension page.

The observer preserves results and the original rejection object, does not consume fetched module bodies, excludes sentinel resource/error text from metadata, and rejects invalid diagnostic enums at the native bridge.

## Firefox WASM process restart

[ExtensionCompatibilityTests.swift](../Tests/BrowseTests/ExtensionCompatibilityTests.swift) optionally verifies real Firefox 1Password WASM startup and account-free onboarding across two separate test processes using shared, unique persistent stores.

Run [test-extension-wasm-restart.sh](../scripts/test-extension-wasm-restart.sh) with BROWSE_TEST_FIREFOX_PACKAGE pointing to a local official XPI. The install phase saves store identifiers and extension origin; the restore phase must instantiate background WASM, retain the origin, and open onboarding without context errors. Both phases decline optional onboarding choices. A dummy native helper prevents desktop-app access. This does not test authenticated accounts, unlock, Touch ID, or the user's existing profile.

## Firefox onboarding smoke test

[ExtensionCompatibilityTests.swift](../Tests/BrowseTests/ExtensionCompatibilityTests.swift) optionally loads a real Firefox 1Password package through Bend's production extension manager in an isolated, windowless profile.

Set `BROWSE_TEST_FIREFOX_PACKAGE` to a local official XPI to run this network-dependent test. It verifies action-driven onboarding, declines three optional choices in disposable data, and follows Sign in to the official email form in the same logical tab. An extension-authorized return reuses the original view and skips the already-answered choices. It enters no credentials and does not establish authenticated sign-in, desktop integration, autofill, or account persistence. Without the environment variable, it returns without loading a real package.

## Extension browser information and menu settings

[[Tests/BrowseTests/ExtensionCompatibilityTests.swift#extensionBrowserSettings]] verifies browser identity, permission approval and revocation, callback errors, and the fixed mouse-down menu setting through real WebKit extension pages.

Set and clear return false, no change events fire, invalid values and private scopes fail, unavailable optional-permission queries return false, and native storage continues working alongside the adapters.

## Foxy Gestures options smoke test

[[Tests/BrowseTests/ExtensionCompatibilityTests.swift#foxyGesturesOptionsSmoke]] optionally loads the real Foxy package from BEND_TEST_FOXY_PACKAGE into isolated storage to verify rendered settings and saved preferences.

The test configures a middle-button downward gesture and exercises native WebKit input against a local page, requiring the extension to open a new tab. No user installation or preferences are changed.

## Extension privacy settings and restored startup

[ExtensionCompatibilityTests.swift](../Tests/BrowseTests/ExtensionCompatibilityTests.swift) verifies privacy approval, persistent grants, disabled saver settings, callback errors, revocation, and startup calls gated on saved configuration across host recreations.

The fixture stores a configured flag before restarting its host, then uses the password-saving and autofill settings during background startup before answering messages. It uses no credentials or real vault. Unsupported enabling is rejected rather than claiming to implement a built-in saver.

## Extension document authentication round trip

[ExtensionCompatibilityTests.swift](../Tests/BrowseTests/ExtensionCompatibilityTests.swift) verifies that same-tab extension-to-website-to-extension navigation preserves session storage and tab identity without giving the website extension privileges.

A local website cannot read the extension's session storage, call the compatibility bridge, or authorize its own return to a privileged document. An explicit extension tab update returns to the retained view with the original setup marker; the flow creates no extra browser pane. Return readiness requires completed navigation and replacement of a document-only marker, since retained session storage is already readable in the old document. Navigation triggers use synchronous JavaScript evaluation so the test does not depend on an injected async function surviving a document transition. Asynchronous API probes retain their promise and result in the document and poll with a bounded timeout, preserving API errors without depending on a collectable injected completion handler.

## Dark Reader compatibility smoke test

[DarkReaderTests.swift](../Tests/BrowseTests/DarkReaderTests.swift) exercises the official Firefox Dark Reader package through Bend's production extension host with temporary storage and a local HTTP page.

Set `BROWSE_TEST_DARK_READER_PACKAGE` to the official 4.9.134 XPI. The test verifies the pinned SHA-256 and package identity, computed dark colors, popup global and per-site toggles, and disable/re-enable with page reloads. The popup runs windowlessly; this checks its DOM controls and messaging, not native popover placement. It does not touch the user's profile or establish compatibility across arbitrary websites. Without the environment variable, the package test is skipped.

## Extension update permissions and resource pages

[ExtensionTests.swift](../Tests/BrowseTests/ExtensionTests.swift) verifies extension pages load with their API namespace and stable identity. An updated extension requesting a new website stays unloaded until its additional access is approved.

The resource-page fixture explicitly permits WebAssembly in its content security policy, instantiates a minimal module, and writes and reads IndexedDB data. This checks the host's runtime primitives independently of third-party startup and native messaging; it does not establish 1Password compatibility.

## Owned extension packages and updates

[ExtensionTests.swift](../Tests/BrowseTests/ExtensionTests.swift) verifies XPI copies survive source removal, replacements preserve origin and storage, invalid or mismatched updates retain the installed version, and new permissions require approval.

Restoration retains the pending approval state. Uninstallation removes managed files while preserving the original package folder.

Storage retention runs in a unique persistent WebKit configuration, separate from the user's profile. Nonpersistent contexts are unsuitable for asserting storage across context replacement because their ephemeral storage is discarded on unload.

## Extension package migration and isolation

[ExtensionTests.swift](../Tests/BrowseTests/ExtensionTests.swift) verifies migration retains identity and grants, owned copies restore after source removal, internal links remain usable, and external symbolic links are rejected.

## Favicon fallback and cancellation

[faviconFallback](../Tests/BrowseTests/FaviconTests.swift) verifies invalid images fall through to a valid WebKit-rasterized icon and cancellation discards a delayed valid response before it can update the pane.

## Favicon request security

[faviconRequestSecurity](../Tests/BrowseTests/FaviconTests.swift) verifies icon loading respects image CSP, rejects redirects outside that policy, requires cross-origin CORS permission, and resists page overrides of image and canvas functions.

Local HTTP fixtures record requests so the test distinguishes blocked network access from a failed decode. CSP denial covers both declared icons and the origin fallback, including a second loopback server. Allowed images still produce a native icon.

## JavaScript dialog origin and responses

[javaScriptDialogOriginAndResponses](../Tests/BrowseTests/JavaScriptDialogTests.swift) verifies all dialog kinds use a real subframe's origin, preserve alert/confirm/prompt completion semantics, and label local or opaque origins safely.

## JavaScript dialog admission and rate limits

[javaScriptDialogAdmissionAndLimits](../Tests/BrowseTests/JavaScriptDialogTests.swift) rejects hidden and background-window callers, coalesces pending requests, isolates windows, and verifies rolling limits survive navigation while user suppression resets on commit.

## JavaScript dialog lifecycle cancellation

[javaScriptDialogLifecycleCancellation](../Tests/BrowseTests/JavaScriptDialogTests.swift) verifies navigation, ancestor hiding, detachment, process termination, and window closure cancel prompts exactly once, even if a stale sheet callback later reports acceptance.

## JavaScript native sheets

[javaScriptNativeSheets](../Tests/BrowseTests/JavaScriptDialogTests.swift) verifies a real AppKit prompt attaches to its browser window, returns entered text, and leaves the application outside an application-modal event loop.

## Favicon history navigation

[[Tests/BrowseTests/FaviconTests.swift#faviconHistoryNavigation]] changes a playing page's URL through the History API while its first icon request is pending, verifying favicon loading recovers without a full document navigation.

## Favicon navigation reset

[FaviconTests.swift](../Tests/BrowseTests/FaviconTests.swift) verifies same-origin links, reloads, and address entry preserve the icon without a placeholder, while redirects to another origin and internal pages clear it.

A delayed local HTTP response checks that the icon stays visible during loading and is replaced after a successful refresh. CSP-blocked refreshes retain the last same-origin icon; late results cannot restore it after leaving the origin. Origin comparison includes scheme, hostname, and effective port.

## Link pane placement

Opening a link splits its source pane to the right even when another pane is focused, preserves neighboring branches and the source URL, and focuses the destination. The result survives serialization; missing source panes leave the tab unchanged.

## Command-click navigation

[LinkNavigationTests.swift](../Tests/BrowseTests/LinkNavigationTests.swift) verifies that WebKit's Command-left-click action opens a pane and cancels source navigation. Ordinary clicks, other buttons, and scripted navigation do not open panes; custom schemes remain blocked.

## Command-click new-window links

[LinkNavigationTests.swift](../Tests/BrowseTests/LinkNavigationTests.swift) verifies that Command-clicking a new-window link opens a pane without creating a tab. An ordinary new-window link still creates a tab.

## Mounted tab switching

[TabSwitchingTests.swift](../Tests/BrowseTests/TabSwitchingTests.swift) switches between real offscreen WebKit tabs and verifies native parents, document identity, unsaved input, and scroll position survive.

Document identity is checked with an injected JavaScript marker and unsaved DOM state, rather than a wall-clock-derived performance timestamp. The test uses local HTTP fixtures and ephemeral storage in a full-content window with a unified toolbar. It checks that the titlebar adds no extra top inset. Narrowing and widening columns verifies CSS viewport width matches the native web view, media queries switch layouts, and resize events fire. Both the HTTP request received by the fixture and JavaScript expose Safari-compatible product tokens plus Bend’s identifier. Unvisited tabs remain uncreated, hidden tabs keep their viewport and ignore other tabs' zoom, selection resizes the active host, and tab or background-pane closure removes retained content.

After switching back beneath a later-mounted hidden tab, the test verifies the inactive hosting root rejects hit tests and each visible pane's center resolves to its web view in None, Transparency, Outline, Outline glow, and Title tint modes. Switching highlight styles preserves the same WebView and native parent. On macOS 26 and later, the web surface reaches the pane’s top edge without a border inset. The test also sends a complete mouse gesture through the window: header press, drag across nine interior points of a real web view, and release. Each point activates the target preview; release rearranges the panes and removes the drag surface while preserving native WebKit parents, document identity, and unsaved input.

The pane and WebView frames stay identical across all focus styles, including Outline with the maximum gap and thickness; decorations consume no layout space.

## Pane drop layout moves

[PaneDropTests.swift](../Tests/BrowseCoreTests/PaneDropTests.swift) checks every source, target, and edge combination in a nested layout, preserving all pane IDs and unrelated split fractions while rejecting missing or identical endpoints.

## Cross-tab pane transfer model

[PaneTransferTests.swift](../Tests/BrowseCoreTests/PaneTransferTests.swift) checks transfers at all four edges across workspaces, source collapse, empty-workspace recovery, detaching, invalid moves, and valid session restoration.

Moving a designated Command-click pane clears the source tab’s designation and does not claim an ordinary pane in the destination.

## Cross-tab native pane dragging

[PaneTransferTests.swift](../Tests/BrowseTests/PaneTransferTests.swift) drives a single-pane tab through sidebar hover into an unvisited tab, drops on its WebKit content, then detaches into sidebar space.

Both sidebar positions exercise native sidebar drop targets, including returning a pane to unused sidebar space.

The test uses the unified titlebar and glass window hierarchy. It verifies delayed-hover cancellation, destination selection, source-tab removal, edge placement, direct row drops before the hover delay, zoomed-pane detaching and row drops, self-row rejection, and saved layouts. Consecutive same-tab drops alternate between panes during hover animation and after focus/layout updates in a key window, and every release must reach the window drag controller. The same live web view, document timestamp, unsaved input, and extension tab adapter survive transfers without creating closed-item history. A missing mouse-up is followed by a press on another pane, which must cancel stale tracking and complete a fresh drag. A whole-tab row-center drop preserves the source split tree, live document timestamp, unsaved input, controller, and extension adapter inside the joined destination. All data and HTTP pages are disposable.

## Pane drop targeting

[PaneDropTests.swift](../Tests/BrowseCoreTests/PaneDropTests.swift) verifies normalized edge selection, half-pane preview frames, and rejection of outside points or empty viewports.

## Pane drop validation and persistence

[PaneDropTests.swift](../Tests/BrowseTests/PaneDropTests.swift) checks hidden, zoomed, stale-pane, and missing-source-tab rejection. A valid move preserves URLs, focuses the moved pane, survives session restoration, and creates no closed-item history.

## Native pane drop lifecycle

[PaneDropTests.swift](../Tests/BrowseTests/PaneDropTests.swift) sends mouse events through an ordered offscreen window to verify preview updates, cancellation without mutation, outside rejection, surface cleanup, and a valid move on release.

The native preview layer is observed during continuous movement and edge changes. It must never transition to hidden while the pointer remains over a valid pane, including between events and layout passes. The drag surface must never intercept hit testing; SwiftUI representable teardown clears the overlay, preview, and tracking before native view removal, and a subsequent drag still works. Teardown and window deactivation leave the window consuming the cancelled gesture until release, then return it to idle.

## Pane header mouse routing

[PaneDropTests.swift](../Tests/BrowseTests/PaneDropTests.swift) sends window mouse events through the actual browser shell, unified titlebar, and glass container in an ordered offscreen window.

Ordinary header hit testing reaches the compact title handles, which drive hover feedback and pane dragging. During a title press, native dispatch instead uses the window-owned mouse target, which accepts first mouse and remains mounted through release. All three mouse event types must pass through AppKit. Mouse-down focuses the pane; small motion does not move the window or begin a drag, and mouse-up clears tracking. Empty header and sidebar backgrounds request native window dragging. Tab rows, toolbar controls, sidebar resize handles, and traffic lights are excluded; native clicks still activate the sidebar toggle without creating a tab.

Background drag gestures cross the native titlebar drag threshold before asserting the request: AppKit can defer the initial mouse-down. Every background window-drag request must originate inside AppKit's normal event dispatch, so activating clicks cannot skip native window appearance bookkeeping. Outside mouse-down dispatch the background targets do not claim hit testing, preserving underlying scroll and hover behavior.

## Pane history controls

[PaneNavigationTests.swift](../Tests/BrowseTests/PaneNavigationTests.swift) verifies Back/Forward through the mounted browser shell using local pages and native mouse events.

The complete focused toolbar stays visible; inactive pane buttons appear together on whole-pane hover without shifting the title or stealing focus. Disabled clicks do not navigate. History clicks focus and navigate only their own pane, preserving other page state. Window deactivation and hidden tabs clear hover, while reactivation refreshes it.

Long titles fill the available header width without overlapping or pushing out the trailing buttons at different window sizes.

## Input logging preference

[InputDiagnosticsTests.swift](../Tests/BrowseTests/InputDiagnosticsTests.swift) verifies logging defaults off, enabling records both streams, the preference survives recreation, and disabling preserves files without appending events.

## Input trace rotation

[InputDiagnosticsTests.swift](../Tests/BrowseTests/InputDiagnosticsTests.swift) verifies native input logs retain recent complete records within two bounded files, including after a writer is recreated.

The test checks repeated rotation discards the oldest segment, oversized records are rejected, queued writes drain, and both files have private permissions.

## Independent input and pane log retention

[InputDiagnosticsTests.swift](../Tests/BrowseTests/InputDiagnosticsTests.swift) verifies heavy input traffic cannot rotate pane activity away, and adopting a smaller size cap removes oversized legacy segments.

## Pane trace correlation

[InputDiagnosticsTests.swift](../Tests/BrowseTests/InputDiagnosticsTests.swift) verifies the press pane survives hiding/removal through release, the receiving pane is reported separately, and a new non-pane press resets attribution.

Both streams share run and sequence identifiers. The trace includes pane attachment and movement activity, preserves all drag events, and excludes keyboard input. Web-view replacement preserves the pane UUID while changing native view identity.

## Input diagnostics during hosting teardown

[InputDiagnosticsTests.swift](../Tests/BrowseTests/InputDiagnosticsTests.swift) destroys real hosting views with tracing active, exercising pane-handle dismantling while their hosting ancestor is deallocating.

Repeated creation and destruction must finish without an Objective-C weak-registration abort. Hosting views and handles must be released, and each dismantled pane handle must produce a removal record with its pane UUID.

## Session round trip

JSON encoding and decoding preserve the selected tab and nested layout. Restore validation rejects missing pages and selected tabs that do not exist.

## Reopening nested pane layouts

[ReopenTests.swift](../Tests/BrowseTests/ReopenTests.swift) verifies exact split restoration without intervening changes and preserves new panes and divider fractions when reopening into an edited layout.

Restoration uses the nearest surviving ancestor when the original sibling is gone, retaining pane order and split direction.

## Closed pane and tab history

[ReopenTests.swift](../Tests/BrowseTests/ReopenTests.swift) verifies a unified last-closed-first history, original workspace selection, focus, zoom clearing, saved URLs, and preservation of subsequent pane edits.

Closing a pane and then its tab reopens them in reverse order without duplicate pages or blank replacement tabs. Reopened layouts persist as valid sessions; closed-item history does not persist.

## Reopen boundaries and background closures

[ReopenTests.swift](../Tests/BrowseTests/ReopenTests.swift) checks background extension closures, final-pane tab closure, invalid pane IDs, preservation of navigated replacement tabs, and the fifty-entry history limit.

## Equal automatic pane sizes

[[Tests/BrowseCoreTests/AutomaticPaneSizingTests.swift#equalAutomaticPaneSizes]] verifies equal widths and heights after repeated splits, closing, reopening, and persistence, with divider gaps excluded and perpendicular subdivisions kept within their column.

## Equal pane sizes after transfers

[[Tests/BrowseCoreTests/AutomaticPaneSizingTests.swift#equalPaneSizesAfterTransfers]] checks equal geometry after cross-tab drops at every edge, same-tab reordering, and joining a whole tab through the sidebar.

## Manual pane sizing intent

[[Tests/BrowseCoreTests/AutomaticPaneSizingTests.swift#manualPaneSizingIntent]] verifies that resizing an automatic three-pane row leaves unrelated boundaries in place, later insertions preserve chosen sizes, and returning to half remains manual after restart.

## Legacy pane sizing migration

[[Tests/BrowseCoreTests/AutomaticPaneSizingTests.swift#legacyPaneSizingMigration]] decodes layouts without sizing metadata and checks that half splits become automatic while unequal legacy fractions remain fixed on insertion.

## Pane geometry and insertion

[PaneGeometryTests.swift](../Tests/BrowseCoreTests/PaneGeometryTests.swift) verifies stable pane identities and exact frames through horizontal and nested vertical splits. Unaffected branches keep their frames, and closing restores the previous geometry.

## Pane geometry bounds

[PaneGeometryTests.swift](../Tests/BrowseCoreTests/PaneGeometryTests.swift) verifies that small viewports grow to fit minimum pane sizes, divider gaps remain consistent, and drag fractions respect both branches' bounds.

## Divider pointer tracking

[PaneResizingTests.swift](../Tests/BrowseTests/PaneResizingTests.swift) sends real window mouse events through horizontal and vertical dividers in an offscreen browser layout.

Clicking and releasing a divider without moving must leave automatic-sizing intent unchanged.

Native hit testing must reach each divider, whose cursor-update tracking selects the appropriate horizontal or vertical resize cursor. Repeated pointer coordinates, forward movement, reversals, and release preserve the expected pane size without feedback from the divider’s changing position. Axis cases run sequentially because they share native mouse-gesture state.

## Divider bounds

Divider updates clamp fractions to safe bounds and leave unrelated split nodes unchanged, preventing extreme drag values from making persisted panes disappear.

## Address resolution

Hostnames, explicit HTTPS, localhost, internal start pages, and search queries resolve correctly. Empty input and explicit non-web URL schemes are rejected, and query punctuation survives URL encoding.

## Location popup requests

[AddressRequestTests.swift](../Tests/BrowseTests/AddressRequestTests.swift) verifies that explicit location requests target the chosen pane, new blank panes prompt after focus changes, and link destinations do not prompt. Invalid pane IDs are ignored.

The store tests use an isolated temporary session-file path. They cover both split directions, blank tabs, and the replacement tab created after closing the final tab. Each automatic request must identify the newly focused pane.

Explicit requests for an existing pane focus that pane; invalid identities produce no request. Opening a link in a right-hand pane or a tab with a supplied URL must not request location entry. These tests exercise store events without instantiating the popup or loading WebKit pages.

## History recording

[HistoryTests.swift](../Tests/BrowseCoreTests/HistoryTests.swift) verifies web-only recording, credential stripping, merging of rapid repeated visits, title updates, and serialization that preserves valid history.

## History matching and completion

[HistoryTests.swift](../Tests/BrowseCoreTests/HistoryTests.swift) checks case- and accent-insensitive matching across titles and decoded URLs. Prefix completion handles explicit schemes and declines short, complete, or multiword queries.

Regression coverage includes bare-host completion of www. URLs, typed-case preservation, explicit www./scheme prefixes, unchanged navigation URLs, and retaining other subdomains.

## History ranking and learned choices

[HistoryTests.swift](../Tests/BrowseCoreTests/HistoryTests.swift) verifies recency, frequency, learned query choices, URL matching, and result limits so suggestions remain relevant and bounded.

## History removal and bounds

[HistoryTests.swift](../Tests/BrowseCoreTests/HistoryTests.swift) verifies eviction at the visit limit, removal from suggestions, and clearing visits and learned choices while retaining a valid model.

## History persistence and clearing

[HistoryStoreTests.swift](../Tests/BrowseTests/HistoryStoreTests.swift) verifies that visits and learned choices survive reloading, that secondary windows share the root database, and that removal and clearing persist independently of session data.

## Unreadable history preservation

[HistoryStoreTests.swift](../Tests/BrowseTests/HistoryStoreTests.swift) verifies that corrupt JSON or SQLite history is reported and preserved during ordinary saves. Explicit clearing permits an empty database to replace it.

## SQLite history transactions

[HistoryDatabaseTests.swift](../Tests/BrowseCoreTests/HistoryDatabaseTests.swift) verifies normalized URL/visit rows, exact timestamp and title round trips, incremental updates, rollback after an injected failure, retry, and deletion of visits and choices.

## JSON history migration

[HistoryDatabaseTests.swift](../Tests/BrowseCoreTests/HistoryDatabaseTests.swift) verifies one-time migration preserves visits and learned ranking, removes the JSON source, prevents reimport after clearing, and leaves unsupported database versions untouched.

## SQLite history retention

[HistoryDatabaseTests.swift](../Tests/BrowseCoreTests/HistoryDatabaseTests.swift) verifies the visit limit persists across reopening, with the oldest visit and its unreferenced URL removed when a new visit exceeds the bound.

## Completed navigation history

[HistoryStoreTests.swift](../Tests/BrowseTests/HistoryStoreTests.swift) checks that completed web navigation records once, title changes update existing history, and later URL changes add visits. Failed navigation and internal pages are excluded.

## Flat tab list restoration

[ReopenTests.swift](../Tests/BrowseTests/ReopenTests.swift) verifies legacy groups merge in order without losing selection, pane identities, layouts, or URLs. New tabs append to the list; close/reopen and saving preserve the single-group session.

## Sidebar tab reordering

[ReopenTests.swift](../Tests/BrowseTests/ReopenTests.swift) exercises upward and downward tab moves, invalid and redundant drops, unchanged selection and live views, and persistence of tab order and pane layouts.

## Sidebar resize tracking and restoration

[PaneResizingTests.swift](../Tests/BrowseTests/PaneResizingTests.swift) drives the sidebar edge in a native window, checking repeated pointer positions, reversals, bounds, repeated drags, pane resizing, live controllers, hide/show, and saved-width restoration.

Both sidebar positions exercise mirrored native dragging. Missing position defaults to left; saved position restores and is shared with secondary and private stores. The allowed range is 200–400 points with a 250-point default. Existing in-range widths remain unchanged; out-of-range widths clamp and nonfinite stored values use the default.

## Sidebar visibility animation

[PaneResizingTests.swift](../Tests/BrowseTests/PaneResizingTests.swift) samples native canvas geometry during sidebar collapse and restoration, checking intermediate positions, final bounds, reversal, and unchanged live WebView/controller identity.

Both sidebar positions are covered. Disabling animations applies the final layout immediately without intermediate frames. Changing sides retains the mounted canvas, native WebView parent, and unsaved form state while moving the canvas to the opposite edge.

## Native sidebar tab dragging

[PaneTransferTests.swift](../Tests/BrowseTests/PaneTransferTests.swift) sends window mouse events through the glass sidebar to verify repeated tab reordering, stable insertion targets, Escape and outside cancellation, selection, recovery from a missing release, and separate close-button handling.

## Pane transfer round trips

[PaneTransferTests.swift](../Tests/BrowseTests/PaneTransferTests.swift) moves the same live pane between two surviving tabs 24 times per layout, using normal and scrolling layouts to check the third drag and later round trips.

The first twenty transfers in each layout hover to select the destination before dropping onto a pane; the remainder drop directly onto the tab row. Each press must reach exactly one visible handle with current tab ownership. AppKit must receive every mouse event through the same window-owned target across transfers, and the window must return to idle after release. Synthetic window events verify retained page controllers, document tokens, unsaved form contents, and unique model ownership while both tab trees remain mounted. Document tokens are injected after navigation and must survive every move; wall-clock-derived performance timestamps are not identity checks.

## Native extension messaging

[ExtensionCompatibilityTests.swift](../Tests/BrowseTests/ExtensionCompatibilityTests.swift) exercises real WebKit native-message calls with an isolated Python echo helper, including restoration, revocation, disconnects, and invalid frames.

One-shot and persistent messages cross the delegate boundary and handle fragmented JSON replies. CI restricts Swift's cooperative pool to one worker to expose blocking pipe reads that would starve other async work. Recreated managers restore permission and reconnect; permission denial and context teardown empty the connection registry. Host crashes and oversized frames reject promises. Unit checks cover Unicode, concatenated frames, manifest allowlists, missing hosts, and traversal rejection. The opt-in Firefox onboarding smoke verifies the real 1Password package requests its registered helper, while an injected resolver prevents access to the user's desktop vault. Touch ID and authenticated desktop unlocking require a separate manual test.

## Extension diagnostic logging

[ExtensionCompatibilityTests.swift](../Tests/BrowseTests/ExtensionCompatibilityTests.swift) verifies diagnostic persistence across logger instances, bounded rotation, owner-only files, safe error categories, and a memory fallback when disk writes fail.

Native-message integration checks require request, resolution, launch, first-send/receive, disconnect, rejection, and exit events, while excluding fixture payloads and Gecko IDs. An extension-page error containing a synthetic secret must emit only its category and error type; arbitrary categories are rejected. These diagnostics do not assert that the user's 1Password account or desktop handshake succeeds.

## 1Password protocol diagnostic redaction

[ExtensionCompatibilityTests.swift](../Tests/BrowseTests/ExtensionCompatibilityTests.swift) verifies that native response summaries expose only known protocol types and error names, never arbitrary response fields or synthetic account secrets.

Success contents are excluded entirely, unknown enum values become a generic label, recognized failure names survive redaction without callback IDs or error prose, and browser identities are decoded only from the protocol's browser_state field with bounded identifier validation. These unit checks do not establish desktop authentication or Touch ID compatibility.

## Configurable link destination

[LinkNavigationTests.swift](../Tests/BrowseTests/LinkNavigationTests.swift) verifies live Command-click destination changes on an existing controller, adjacent placement, source preservation, ordinary new-window behavior, and main-frame opener tracking.

Link-created tabs insert immediately after the active tab, ahead of existing later tabs, for both Command-click and ordinary new-window links.

## UI preference persistence

[AddressRequestTests.swift](../Tests/BrowseTests/AddressRequestTests.swift) verifies legacy session defaults, preference persistence across store recreation, preserved tab identity, and numeric bounds and nonfinite-value handling.

Window/header appearances persist independently, including the solid header color and style, preserve legacy defaults, and support resetting both appearances. Top- and bottom-rim clipping default independently for legacy sessions, persist fractional values, delegate through secondary windows, and clamp invalid input. Sessions containing retired custom separator settings still load without affecting the clipping defaults or tabs.

Highlight settings preserve separate colors, outline gap and width, intensity, spread, and mode across restart, including None mode and retained title-tint color and intensity; absent highlight settings use None. Older records without an outline gap receive the default gap. Older records without spread decode with their previous intensity-derived radius; records without title-tint fields receive the default color and intensity. Invalid colors and nonfinite numeric values normalize to defaults, and out-of-range values are bounded.

## Home page suggestion ranking

[HistoryTests.swift](../Tests/BrowseCoreTests/HistoryTests.swift) reproduces a deep link with one learned choice competing with 35 home-page visits. Host prefixes prefer the home page, path searches retain deep links, and frequent visits can outweigh learned choices.

Bare-host prefixes also prefer a www. home page over a much more frequently visited article; omitting www. from a path query still finds and completes the deep link.

## Remove address suggestion

[HistoryStoreTests.swift](../Tests/BrowseTests/HistoryStoreTests.swift) exercises a popup row’s removal button and verifies immediate result refresh, persisted removal of visits and learned choices, and no navigation.

## Live window glass preferences

[AddressRequestTests.swift](../Tests/BrowseTests/AddressRequestTests.swift) verifies style and tint update on the existing native window glass, header changes leave it alone, and reset clears tint without replacing content.

## Solid header appearance

[[Tests/BrowseTests/AddressRequestTests.swift#solidHeaderAppearance]] verifies legacy style migration, retained solid color across style changes and serialization, and invalid-color normalization.

Native and SwiftUI bitmap renders must both be opaque, lighter than the chosen color at the top, darker at the bottom, and visually equivalent within channel tolerance. Maximum glass darkening and rim clipping cannot affect solid paint.

## Joining tab layouts

[PaneTransferTests.swift](../Tests/BrowseCoreTests/PaneTransferTests.swift) verifies joins preserve both split trees, page identities, destination title, and source focus, remove the source tab, and survive serialization.

Same-workspace and cross-workspace joins retain valid sessions, including replacement of an emptied workspace. Self-joins and missing endpoints leave the session unchanged. A join retains the destination’s dedicated Command-click pane when present, otherwise adopts the source’s; that designation also survives serialization.

## Independent browser windows

[BrowserWindowTests.swift](../Tests/BrowseTests/BrowserWindowTests.swift) checks independent tabs and address panels, shared history updates and preferences, live glass propagation, and preservation of the other window's controllers and extension adapters on close.

## Browser window restoration

[BrowserWindowTests.swift](../Tests/BrowseTests/BrowserWindowTests.swift) verifies per-window layouts and selection survive quit, closing one window removes it from restoration, final-window closure preserves it, and preferences persist after the primary closes.

The test also closes every registered extension window and opens a new one, checking that retired adapters stay detached and the shared manager registers the new window correctly.

## New window keyboard command

[BrowserWindowTests.swift](../Tests/BrowseTests/BrowserWindowTests.swift) dispatches Command-N through the native menu, checks that it creates a separate blank browser window, and verifies tab commands follow focus between both windows.

Focus transitions use the native window delegate notification so offscreen desktop activation is not a prerequisite.

## Tab merge placement

[PaneTransferTests.swift](../Tests/BrowseCoreTests/PaneTransferTests.swift) checks all four merge edges, intact source trees, untouched destination branches and fractions, focus, title, persistence, and atomic rejection of stale or foreign target panes.

## Tab drag hover and merge placement

[PaneTransferTests.swift](../Tests/BrowseTests/PaneTransferTests.swift) drives native tab drags through delayed selection and all four pane-edge merges, checking timer cancellation, zoom exit, preview cleanup, and preservation of live page and extension identities.

## Canceling new tab entry

[AddressRequestTests.swift](../Tests/BrowseTests/AddressRequestTests.swift) verifies that canceling initial blank-tab or split-pane entry restores the previous focus, layout, and zoom without recording a closed item.

Both split directions restore a non-first source pane, preserve its controller, and dispose of the provisional controller. The saved session excludes canceled panes and tabs; a pane that has navigated is retained. Existing tabs, completed entry, tabs with added panes, and tabs opened with a destination cannot be discarded through this path.

## New tab popup keyboard cancellation

[AddressRequestTests.swift](../Tests/BrowseTests/AddressRequestTests.swift) exercises Escape and Command-W through the native popup and application menu after creating a tab or using Command-D and Shift-Command-D.

Both commands dismiss the popup and remove the initial blank pane or tab even after unsubmitted editing. Existing-pane Escape, outside dismissal, and successful submission retain their content. The placeholder uses the system placeholder text color.

## Dedicated Command-click pane

[LinkNavigationTests.swift](../Tests/BrowseTests/LinkNavigationTests.swift) verifies one reusable link destination per tab, including stable pane and WebView identity across repeated links.

Clicks from different source panes reuse the target, independent tabs receive independent targets, and iframe/self links avoid stale or self-referential openers. Closing, reopening, replacing, restarting, and switching settings preserve the intended designation and page counts. Closing all ordinary panes promotes the surviving destination without replacing its WebView; the next link creates a new reusable target. Legacy single-pane designations are cleared on restoration.

## Command-click preference migration

[LinkNavigationTests.swift](../Tests/BrowseTests/LinkNavigationTests.swift) verifies that both legacy link-opening choices survive loading and that the dedicated-pane choice persists without replacing existing tabs.

## Page zoom shortcuts

[PageZoomTests.swift](../Tests/BrowseTests/PageZoomTests.swift) invokes native menu shortcuts against two web panes to verify zoom-in aliases, zoom-out, reset, focused-pane isolation, bounds, and disabled internal or hidden pages.

Changing page zoom preserves an injected document marker and edited form contents and leaves the independent pane-maximizing layout mode untouched. Native magnification is enabled, scales only one pane, and remains independent of keyboard page zoom. The test applies magnification through WebKit’s public API; physical trackpad gesture delivery requires a manual check.

## Find in page

[FindInPageTests.swift](../Tests/BrowseTests/FindInPageTests.swift) exercises the Command-F menu against real WebKit documents, checking focused-pane routing, case-insensitive matches, next/previous wrapping, scrolling, header clearance, Escape dismissal, and disabled internal-page commands.

Actual window mouse clicks on the shared-style find buttons navigate forwards and backwards and dismiss the bar, clearing highlights and returning focus to the web page.

Layout assertions verify that the input keeps its frame across empty, pending, matching, and zero-result states, including at minimum pane width. Empty focused and cleared input keep the caret beyond the search icon and vertically inside the field, including at minimum width. The count stays right-aligned inside the field without overlapping the native text editor. Return and Find Next retain the count while navigating; editing the query immediately clears the old total.

On macOS 26 and later, the find controls share the native title glass without a separate material. Opening and closing adjust the visible header height and WebKit inset together; style and tint changes preserve the field editor and control parentage. Switching repeatedly between solid and glass hides the unused background, preserves the chosen solid color, and keeps find geometry, control parents, and WebKit insets unchanged. The glass extends above and below a clipping container to hide its top and bottom rims, while controls retain the visible header's coordinates. Live top- and bottom-clipping changes at zero, fractional, and maximum values preserve the find row, field editor, and WebKit inset. Active-pane tint spans the combined header, covers the find row, stays absent from inactive panes, and clears without removing the controls.

Match-count assertions cover case-insensitive totals, hidden-text exclusion, zero and empty queries, and matches inside an iframe. Dismissal checks clear main-frame and iframe selections, preserve scroll, and reject late count results; reopening searches the retained query again. Repeated Escape presses after dismissal still reach page key listeners without crashing. Cancellation is also safe with no bar or before mounting a web view.

## Settings close shortcut

[BrowserWindowTests.swift](../Tests/BrowseTests/BrowserWindowTests.swift) verifies Command-W closes the focused Settings window without changing browser panes, still closes a focused browser pane, and cancels a new tab from its address popup.

The test dispatches real menu key equivalents with an explicit focused-window provider, avoiding dependence on desktop activation in a headless test host. The native Settings window hides the centered window title and keeps full-size content, with a transparent titlebar before content scrolls beneath the section heading.

## Settings section toolbar

[BrowserWindowTests.swift](../Tests/BrowseTests/BrowserWindowTests.swift) verifies that the native Settings toolbar contains the section title and that sidebar selection updates the window title for UI, Websites, Extensions, and Development.

The toolbar test verifies targeted Extensions presentation in fresh, visible, and reopened Settings windows, and that general presentation preserves the current selection. It also verifies reopening centers Settings on each available screen after moving it offscreen. It scrolls overflowing detail content beneath the stationary title and back to the top, checking that native titlebar transparency changes with the overlap. It also verifies native toolbar insets and fixed width bounds across all sections while allowing vertical resizing. The visible sidebar stays 200 points wide across section changes, including attempts to move the native divider in both directions; assertions exclude OS-dependent margins on the native split-item wrapper.

## Pane-centered location popup

[AddressRequestTests.swift](../Tests/BrowseTests/AddressRequestTests.swift) verifies that location popups center horizontally on their target pane, start one-fifth down it, and retain their initial top edge while open.

The native-view regression covers separate left/right targets, result growth and shrinkage, validation errors, pane resizing and clipping, fresh placement after reopening, and retaining the fallback top when a pane mounts later.

## Website setting identity

[WebsiteSettingsTests.swift](../Tests/BrowseCoreTests/WebsiteSettingsTests.swift) verifies hostname normalization, path/scheme/port sharing, distinct subdomains, internal-page exclusion, and valid zoom bounds.

## Website settings transactions

[WebsiteSettingsTests.swift](../Tests/BrowseCoreTests/WebsiteSettingsTests.swift) verifies default and override persistence, atomic rollback after an injected write failure, retry, deletion, and invalid-value rejection.

## Website settings storage protection

[WebsiteSettingsTests.swift](../Tests/BrowseCoreTests/WebsiteSettingsTests.swift) verifies corrupt files are preserved and unrelated or newer databases are rejected without adopting their contents.

## Website security migration

[[Tests/BrowseCoreTests/WebsiteSettingsTests.swift#websiteSecurityMigration]] verifies legacy zoom settings survive migration, new security preferences start with compatible defaults, and all four Boolean choices persist after reopening.

## Website security preferences

[[Tests/BrowseTests/WebsiteSettingsTests.swift#websiteSecurityPreferences]] verifies real website JavaScript is disabled and re-enabled on navigation, fraud warnings and cookie policy update live, and HTTP warnings select WebKit’s user-mediated fallback.

## Website zoom navigation and sharing

[WebsiteSettingsTests.swift](../Tests/BrowseTests/WebsiteSettingsTests.swift) verifies persisted zoom across panes, windows, and store recreation, using local HTTP pages with redirects, iframe loads, and back/forward navigation.

Default changes, explicit 100% overrides, individual/all resets, and history clearing preserve the intended website preference boundaries. Existing pages update without reloading; internal pages stay at 100%.

## Website zoom during provisional navigation

[WebsiteSettingsTests.swift](../Tests/BrowseTests/WebsiteSettingsTests.swift) verifies a delayed destination cannot resize the outgoing page before commit, and a failed navigation keeps its zoom and settings ownership.

Live settings changes during the delay affect the visible source document; the destination’s latest preference applies at commit. Redirects never apply an intermediate host’s preference to the outgoing document.

## Website settings failure recovery

[WebsiteSettingsTests.swift](../Tests/BrowseTests/WebsiteSettingsTests.swift) verifies unreadable settings surface an error without overwriting the file, and retry restores persistence after storage is repaired.

## Closing the last browser pane

[BrowserWindowTests.swift](../Tests/BrowseTests/BrowserWindowTests.swift) verifies Command-W closes an exhausted window when another browser remains, but replaces the sole window’s last pane with a blank pane and focused address popup.

The closed page remains reopenable. Repeating Command-W from the popup keeps the sole browser open; explicit native closure still closes it, and close commands with no browser do not mutate saved state.

## Pane shadow boundaries

[PaneShadowTests.swift](../Tests/BrowseTests/PaneShadowTests.swift) renders the shadow layer to a bitmap, checking visible falloff beyond canvas bounds, clear pane interiors, ignored hit tests, and updates for moved or hidden panes.

The neutral outer edge fades in through the header, leaves the top rim unlit, keeps pane interiors clear at its fixed subtle intensity. The bitmap checks also verify that glow colors only the focused pane’s shadow, follows focus changes, respects intensity and spread, and has matching top/bottom and left/right falloff. Leaving glow mode restores the ordinary black shadow. Outline checks cover independent gap and thickness, drawing beyond the canvas, focus changes, hiding, and clear pane interiors even when a thick ring reaches a neighbor.

## Cross-window live transfers

[CrossWindowDragTests.swift](../Tests/BrowseTests/CrossWindowDragTests.swift) verifies whole-tab and repeated pane transfers preserve live documents, form edits, both zoom modes, controller ownership, callbacks, and extension adapters.

Invalid source or destination IDs leave models untouched. Both sessions remain valid, a source with remaining tabs stays open, moves add no closed-history items, saved layouts reflect the transfer, and closing the source does not stop transferred pages.

## Cross-window drag gestures

[CrossWindowDragTests.swift](../Tests/BrowseTests/CrossWindowDragTests.swift) drives native pane gestures and sidebar tab handles between two mounted browser windows, checking destination previews, cancellation, insertion, and WebView attachment.

The pressed window receives pointer coordinates even over another window. Pane and sidebar previews raise the destination above other browser windows while preserving the key window and active drag. Cancelled drags clear the remote overlay and leave ownership unchanged; successful moves clean up tracking and mount the original WebView in its destination.

## Empty window transfer cleanup

[CrossWindowDragTests.swift](../Tests/BrowseTests/CrossWindowDragTests.swift) verifies moving the final tab or pane closes only the source window, preserves the live destination document and extension adapter, and removes the source from restoration.

Invalid drops leave both windows open. The surviving window retains unsaved form contents, no closed-history entry is created by the transfer, and reopening restores only the destination window and its transferred page.

## Window control alignment

[[Tests/BrowseTests/BrowserWindowTests.swift#windowControlAlignment]] verifies native traffic lights align with pane titles in new regular and private windows, before and after resizing and sidebar toggles, while another window changes fullscreen toolbar visibility.

Both sidebar positions preserve upper-left traffic-light geometry and keep pane title hit regions clear of the controls in regular and private windows.

## Default browser selection

[DefaultBrowserTests.swift](../Tests/BrowseTests/DefaultBrowserTests.swift) verifies both web schemes are required for default status, combined system changes avoid duplicate requests, and cancellation and failure leave the control ready to retry.

Injected handler queries and requests keep these tests from changing the user's actual default browser. Refresh detects changes made outside Bend; failure produces an error while cancellation does not.

## External web links

[DefaultBrowserTests.swift](../Tests/BrowseTests/DefaultBrowserTests.swift) verifies web URLs received before launch finishes open after restoration, later links target the active window, and existing tabs remain intact.

Multiple URLs preserve order, query strings, and fragments. Unsupported schemes are ignored, the pending queue drains once, and external links do not open a blank address popup.

## Fullscreen chrome transitions

[BrowserWindowTests.swift](../Tests/BrowseTests/BrowserWindowTests.swift) enters and exits native fullscreen, verifying toolbar auto-hiding, unobstructed title hit testing, sidebar toggles, restored windowed geometry, and retained document state.

Run with `BEND_FULLSCREEN_TEST=1` because the test activates a temporary app window and changes macOS Spaces. It checks full-height content layout, a compact rollover titlebar no taller than 32 points with vertically centered traffic lights, removal of traffic-light reservation in fullscreen, dismissal of an old address popup, and preservation of unsaved form data through exit. The original toolbar visibility and window-control position must return on exit.

## Page fullscreen availability

[ElementFullscreenTests.swift](../Tests/BrowseTests/ElementFullscreenTests.swift) loads a browser page and verifies the document reports fullscreen enabled and exposes the video request API without entering fullscreen automatically.

## Dock download progress

[[Tests/BrowseTests/DownloadTests.swift#dockDownloadProgress]] verifies native file progress stays unfinished until publication succeeds, uses the collision-resolved URL, and cancels failed operations without reporting completion.

Windowless progress omits animation metadata, and finishing twice has no effect. Visual animation remains controlled by the macOS Dock.

## Website downloads

[DownloadTests.swift](../Tests/BrowseTests/DownloadTests.swift) uses real WebKit navigation to download attachments, explicit links, unsupported MIME types, redirects with cookies, POST responses, and blob/data files while preserving the source document.

Existing filenames must remain unchanged, repeated downloads receive distinct names, completed transfers leave no staging folders, and clearing the list preserves downloaded files.

Converting navigation into a download must not display a page error, while genuine connection errors remain visible.

## Download cancellation and retry

[DownloadTests.swift](../Tests/BrowseTests/DownloadTests.swift) cancels a throttled transfer after progress arrives, releases its source controller, retries to completion, and verifies an HTTP failure can be retried without publishing its error body.

A separate running transfer must finish after its source web view is released.

## Download filenames

[DownloadTests.swift](../Tests/BrowseTests/DownloadTests.swift) checks traversal paths, Windows separators, hidden names, control and directional characters, and oversized Unicode names become bounded filenames; unsupported URL schemes cannot start downloads.

## Download destination preferences

[DownloadTests.swift](../Tests/BrowseTests/DownloadTests.swift) verifies the download folder defaults to Downloads, persists across store recreation, and is shared across windows.

An active transfer keeps its original destination after a preference change, while the next download uses the new folder. Resetting to Downloads removes the custom preference.

## Download-only tabs

[DownloadTests.swift](../Tests/BrowseTests/DownloadTests.swift) opens real new-window download links, directly and through redirects, verifying their temporary tabs disappear while transfers complete and the source document remains intact.

Cleanup restores the preceding tab only if the temporary tab is still selected, does not add closed-tab history, and retains tabs that committed a document before downloading.

Context-menu background tabs load real pages without activation. Download-only background tabs disappear without changing the source selection or zoom, creating closed-tab history, or disturbing unsaved form input.

## Download database retention and transactions

[DownloadDatabaseTests.swift](../Tests/BrowseTests/DownloadDatabaseTests.swift) verifies SQLite round trips, stable order, 256-record pruning, transactional rollback after an injected failure, retry, and durable clearing without deleting files.

## Download history recovery

[DownloadDatabaseTests.swift](../Tests/BrowseTests/DownloadDatabaseTests.swift) preserves unreadable storage, retries after repair, and restores unfinished transfers as interrupted without replaying POST requests or starting downloads automatically.

## Persistent download history

[DownloadTests.swift](../Tests/BrowseTests/DownloadTests.swift) recreates the manager after real completed and interrupted downloads, retries a restored GET, and verifies durable clearing and automatic retention while saved files remain intact.

## Combined download progress

[DownloadDatabaseTests.swift](../Tests/BrowseTests/DownloadDatabaseTests.swift) verifies byte-weighted progress across transfers, unknown-size and idle states, bounded invalid counts, and large byte totals without integer overflow.

## Downloads with collapsed sidebar

[DownloadTests.swift](../Tests/BrowseTests/DownloadTests.swift) verifies one visible Downloads control remains inside the window across sidebar toggles, pane zoom, and tab switching, beside the sidebar toggle when collapsed; clearing the list removes it.

Both controls retain their 28-point size and two-point gap in expanded and collapsed layouts.

## External application consent

[ExternalApplicationLinkTests.swift](../Tests/BrowseTests/ExternalApplicationLinkTests.swift) verifies generic custom schemes open only after approval, preserve the destination URL, and use the resolved application shown in the prompt.

Cancellation never launches an app. Missing handlers and launch failures are reported, internal schemes are excluded, and the displayed page origin omits credentials and URL payloads. App lookup, confirmation, and launch are injected so tests never open a real external app.

## External application prompt coalescing

[ExternalApplicationLinkTests.swift](../Tests/BrowseTests/ExternalApplicationLinkTests.swift) verifies repeated requests share no queue: a pending window blocks a second prompt, cancellation permits retry, and a hidden window cannot launch an app.

The test holds the confirmation asynchronously to exercise requests arriving before the first decision and window hiding before approval completes.

## WebKit external application routes

[ExternalApplicationLinkTests.swift](../Tests/BrowseTests/ExternalApplicationLinkTests.swift) exercises real WebKit normal links, scripted redirects, new-window links, and iframe launchers using a synthetic custom scheme.

Each navigation produces exactly one mocked app launch, preserves the source document without a navigation error, identifies the source origin, and does not create an empty browser tab.

## Local web documents

[DefaultBrowserTests.swift](../Tests/BrowseTests/DefaultBrowserTests.swift) verifies local HTML received through the app delegate loads with relative JavaScript assets and survives recreation from the saved file URL.

HTML and XHTML are accepted, while other file types and remote file hosts are rejected. Directory containment rejects paths outside the document’s directory.

## Link hover preview

Verify relative, nested, shadow-root, and iframe links display their destinations through an isolated WebKit bridge. Leaving a link and navigating clear the preview; its bounded pane-local bubble ignores clicks.

Pointer movement within one link switches the preview to the right and back without duplicate URL messages or oscillation. Long URLs truncate clear of the cursor at either edge, including after a pane resize. Short and long GitHub URLs fit their full text when the pane has room; changing URLs recomputes the width. Rendered previews must match the same label with truncation disabled, catching internal text-cell padding that geometric assertions miss. `BEND_URL_PREVIEW_SNAPSHOTS` optionally saves those renders for visual inspection.

## Developer tools

[DeveloperToolsTests.swift](../Tests/BrowseTests/DeveloperToolsTests.swift) opens the native inspector through the Develop menu shortcut and checks that console errors, thrown errors, and unhandled rejections from the selected pane reach its console.

Two mounted pages verify source isolation and focused-pane routing. Command-Shift-I toggles the inspector below its page in the same pane. The native toolbar switches between right and bottom docking without losing console messages, and its close button removes the panel. Inspecting a real DOM element before docking, plus a repeated native reveal in a narrow page, must keep the frontend in its original panel and window with no empty dock region. Mouse drags resize both dock positions without moving the browser window. Reopening and find-bar coexistence preserve separate page/inspector bounds, including narrow panes. The inspector control bridge is absent from the inspected website. Left docking and detaching stay hidden; closure removes the frontend, and commands disable on native Bend pages. `BEND_INSPECTOR_SNAPSHOT` optionally captures the containing browser window. Run this AppKit test without parallel execution because it owns the shared application menu.

## Pinned pane protection

[[Tests/BrowseTests/PinningTests.swift#pinnedPaneProtection]] verifies pins survive reload, older pages default to unpinned, and protected pane/tab closure preserves controllers, layout, zoom, and closed history.

Tab pinning sets all pane pins; individual unpinning keeps the tab protected while any pin remains. Unpinned siblings can close and reopen. Pinned blank-entry and download tabs survive automatic cleanup, and reopening a closed tab retains a pinned replacement.

## Pinned pane transfers

[[Tests/BrowseTests/PinningTests.swift#pinnedPaneTransfers]] moves a pinned pane across tabs, detaches and rejoins it, then transfers it between windows, preserving its pin, live WebView, session validity, and persisted state without closed history.

## Pinned close commands

[[Tests/BrowseTests/PinningTests.swift#pinnedCloseCommands]] verifies Command-W cannot close the final pinned pane's window, native close requests are refused while pinned, and unpinning restores normal last-pane window closure.

## Native pin controls

[[Tests/BrowseTests/PinningTests.swift#nativePinControls]] exercises native Option-clicks on pane controls and sidebar rows, checks the live modifier preview, and unpins an inactive pane and an unselected tab through their always-visible pin buttons.

## Detached window ownership

[[Tests/BrowseTests/DetachedWindowTests.swift#DetachedWindowTests#detachedWindowOwnership]] verifies pane and whole-tab detachment preserves live WebViews, form state, page zoom, pins, and saved window membership without an extra blank tab or closed history.

Whole-tab detachment preserves split layout, tab identity, and the dedicated-link pane. Exhausted source windows close after transfer, while a source with remaining panes stays open. Invalid sources create no window, and destination frames fit the chosen display.

## Outside-window drag gestures

[[Tests/BrowseTests/DetachedWindowTests.swift#DetachedWindowTests#outsideWindowDragGestures]] drives native pane and tab gestures through the threshold, outside preview, return, cancellation, and successful release into a new window.

The preview remains mouse-transparent and nonactivating, grows outside, shrinks on return, and does not mask the source window as a drop target. Near-edge size hysteresis leaves exact outside-drop eligibility unchanged. No destination exists before release; cancellation clears the panel and retains ownership. Both final drop paths leave no preview or extra blank tab. `BEND_DRAG_PREVIEW_SNAPSHOT` optionally captures the expanded card for visual review.

Tab drags retain a compact title badge inside their source window, show the thumbnail after leaving, and restore the badge on return; repeated boundary crossings do not leave both visuals visible.

## Drag preview motion

[[Tests/BrowseTests/DetachedWindowTests.swift#dragPreviewMotion]] moves the preview continuously while it grows and shrinks, verifying its cursor anchor never trails the latest pointer or jumps back to an earlier position.

After motion stops, the size transition must finish at the requested dimensions without moving the cursor anchor. Landscape and portrait sources retain their thumbnail aspect ratio without extra space in compact, expanded, and intermediate sizes; both outer dimensions remain within the 250-point cap. This regresses competing panel-position and resize animations.

## Clipped resize cursors

[[Tests/BrowseTests/PaneResizingTests.swift#clippedResizeCursors]] exercises pane and sidebar resize handles outside a clip view, then visible, hidden, empty, and detached, ensuring invalid cursor rectangles never reach AppKit.

The fully clipped case has a null intersection with an infinite origin, matching the cursor-registration crash. Visible handles still register their resize regions.

## Drag preview rendered proportions

[[Tests/BrowseTests/DetachedWindowTests.swift#dragPreviewRenderedProportions]] renders wide, tall, and shallow pane previews, checking that captured squares stay square and web content reaches the thumbnail edges after capped resizing.

A web-only snapshot occupies its original content rectangle inside the miniature pane, retaining header geometry. Long titles must truncate rather than widen portrait cards. Compact, expanded, and restored compact renders preserve proportions within native pixel rounding without letterboxing; shallow panes retain their captured height rather than layout minimums.

## Command-Shift-click destinations

[[Tests/BrowseTests/LinkNavigationTests.swift#commandShiftClickDestinations]] verifies independent Command-Shift-click preferences across WebKit navigation and popup callbacks, preserving the source while opening a new tab, pane, or window.

Missing settings default to New tab and insert below the active sidebar row. New panes are adjacent without claiming the dedicated Command-click pane, and iframe links omit opener metadata. Ordinary Command-click retains its own mode. New windows contain one destination pane and persist the URL and window membership. Changes through secondary stores reach existing controllers; all three choices persist independently of Command-click.

## Drag preview glass isolation

Drag thumbnails must not bitmap-render a live pane or disturb its native glass, page state, or viewport.

[[Tests/BrowseTests/DetachedWindowTests.swift#dragPreviewGlassIsolation]] mounts a real web surface with glass, waits for a WebKit thumbnail, and rejects native pane captures. The visible snapshot excludes the header; showing and cancelling the preview preserves the header instance and frame, WebView ownership and geometry, content inset, and document state.

## Header glass after window transfer

Moving a live page between windows must preserve a single header material, viewport geometry, scrolling, and unsaved document state.

[[Tests/BrowseTests/HeaderGlassTransferTests.swift#headerGlassAfterWindowTransfer]] mounts two identical pages, repeatedly detaches one into a new window and returns it, then compares the moved and untouched headers. The real WebKit scroll-pocket view remains hidden while Bend's glass stays visible. Scrolling down and back to the top and switching tabs preserve suppression, the content inset, live controller, document token, and form value. A full-app visual check of the reported Hacker News page confirms matching headers after the same round trip.

## Extension update metadata

[[Tests/BrowseTests/ExtensionUpdateTests.swift#extensionUpdateMetadata]] verifies Mozilla package metadata and GitHub release-page parsing, including exact Safari asset/checksum association, duplicate or missing assets, foreign hosts, invalid tags, changed markup, and numeric version comparisons.

## Automatic extension updates

[[Tests/BrowseTests/ExtensionUpdateTests.swift#automaticExtensionUpdates]] exercises manual and scheduled checks, request coalescing, persisted preferences, explicit and automatic installation, permission review, failure retention, and removal during download.

Fixtures use isolated extension storage and injected network boundaries. Scheduling checks cover the four-hour interval, persisted results and failures reused on startup, restored update candidates, explicit checks bypassing the cache, and future-dated cache rejection. The installed extension retains its origin, and downloads run without holding the manager’s mutation lock. [[tests#Owned extension packages and updates]] separately verifies native storage preservation and transaction rollback.

## Extension update service smoke test

[[Tests/BrowseTests/ExtensionUpdateTests.swift#extensionUpdateServiceSmoke]] optionally queries the official release pages or APIs and downloads each published package with digest validation, without installing it or modifying the user profile.

Set `BROWSE_TEST_EXTENSION_UPDATES=1` to enable all live network checks, or supply comma-separated catalog IDs to select sources. Public-service rate limits remain real failures; no application credentials are used.

## Safari direct-download migration

[[Tests/BrowseTests/UBlockLiteTests.swift#safariUBlockDirectMigration]] replaces the real Safari bundle with its official release ZIP in isolated persistent storage and verifies UUID, origin, enablement, saved data, and restoration.

Set `BROWSE_TEST_UBLOCK_SAFARI_PACKAGE` to the ZIP and `BROWSE_TEST_UBLOCK_SAFARI_PREVIOUS` to the app extension bundle. The package contents remain unmodified, and [[tests#Safari uBlock Lite compatibility]] additionally exercises detection and request blocking with the ZIP.

## Build profile isolation

[[Tests/BrowseTests/AppProfileTests.swift#buildProfileIsolation]] verifies separate debug and production names, bundle IDs, support directories, preference domains, window-state keys, and WebKit store identities.

A unique temporary preference and cookie marker written in Debug must be absent from production, and both markers are removed after the test. Store wrappers remain retained throughout the async cookie checks. The debug extension manager must use the debug extension and website stores. Simulated packaged-host identities must select standard UserDefaults, covering the case missed by a test bundle with a different identifier. The signed executable’s `--print-build-profile` path also reads preferences before returning. [[tests#Build bundle publication]] and [[tests#Production installer publication]] verify the packaging boundary independently of runtime storage.

## Favorite tabs and persistence

[[Tests/BrowseTests/FavoritesTests.swift#favoriteTabsAndPersistence]] verifies the nine-site cap, duplicate handling, tab-to-tile representation, original-URL reopening, lazy restoration, invalid URL rejection, removal, and compatibility with older sessions.

## Shared favorites and pane transfers

[[Tests/BrowseTests/FavoritesTests.swift#sharedFavoritesAndTransfers]] verifies shared favorites across windows, separate live instances, association preservation during transfers and splitting, focused-pane selection, persistence, and removal from another window.

## Favorite favicon snapshots

[[Tests/BrowseTests/FavoritesTests.swift#favoriteFaviconSnapshots]] verifies late favicon capture, persisted PNG restoration without creating a WebView, rejection of cross-origin icon replacements, and validation of duplicate, invalid, or oversized saved entries.

## Favorite tile interaction

[[Tests/BrowseTests/FavoritesTests.swift#favoriteTileInteraction]] mounts nine tiles in a native window, verifies the three-column layout and window-drag exclusions, and clicks a tile through native mouse dispatch to select its hidden sidebar tab.

## Google favorite account URLs

[[Tests/BrowseTests/GoogleFavoriteTests.swift#googleFavoriteAccountURLs]] checks exact host recognition, email validation, plus-tag encoding, Google chooser destinations, account-hint prefill, spoofed URL rejection, and older favorite decoding.

## Google favorite customization lifecycle

[[Tests/BrowseTests/GoogleFavoriteTests.swift#googleFavoriteCustomizationLifecycle]] verifies optional-email creation, invalid input and cancellation, original-target validation, multiple accounts, duplicate prevention, editing, removal of account targeting, and account-specific session restoration.

## Favorite location entry preserves the source

[[Tests/BrowseTests/GoogleFavoriteTests.swift#favoriteLocationEntryPreservesSource]] submits the native location popup from a favorite and verifies a new unassociated tab opens while the source URL and WebView survive. Same-origin entries remain in place; searches open separately and stale targets are ignored.

## Google favorite popup presentation

[[Tests/BrowseTests/GoogleFavoriteTests.swift#googleFavoritePopupPresentation]] opens the Google account sheet from a browser window, verifies its editable email field, and dismisses with Escape without creating a favorite or changing the tab.

## Release metadata and changelog

[[scripts/test-release.py#ReleaseTests]] runs real Changie in disposable repositories to verify version-driven release preparation and PR checks without changing the working project.

The tests verify fragment consumption, validation when a clean checkout omits the empty fragment directory, malformed-fragment rejection, matching version notes and changelog generation, refusal to reuse or decrease versions, baseline initialization without a release trigger, invalid version rejection, required fragments for user-facing changes, the internal-only escape, stale changelog detection, immutable historical release notes, a merged version bump detected against the push boundary, a later unchanged-version push that does not release, and a revised untagged candidate that requests a fresh release without changing VERSION. Tagged candidates and older notes remain immutable; revisions must consume all pending fragments. Run `python3 scripts/test-release.py`; no signing credentials are required.

## CI signing credential lifecycle

[[scripts/test-ci-signing.py#SigningTests]] verifies temporary credential handling with mocked system commands, without touching a real keychain or contacting Apple.

Coverage includes restrictive file permissions, raw credential removal after import, original keychain search-list restoration, cleanup after notarization setup failure, removal even when keychain commands fail, and missing-secret rejection before system changes. Run `python3 scripts/test-ci-signing.py`.

## GitHub release publication

[[scripts/test-publish-release.py#PublicationTests]] exercises release publication with temporary build artifacts and a simulated GitHub service, without pushing tags or creating real releases.

Coverage includes exact-commit tags, complete asset upload before publication, draft recovery after partial upload failure, rejection of conflicting tags and mismatched checksums, notes, or provenance, upload digest verification, and reruns that leave published binaries untouched. [[scripts/test-publish-release.py#APIErrorTests]] distinguishes a missing resource from permission or network errors so API failures cannot silently trigger creation. Run `python3 scripts/test-publish-release.py`.

## Title URL preview

[[Tests/BrowseTests/LinkHoverPreviewTests.swift#titleURLPreview]] sends native hover events to a pane title handle and verifies the page URL appears in the existing bottom preview even when the pointer is above page content.

Delayed DOM link events cannot erase or replace the title URL while the pointer is in the header. Entering page content gives the hovered link priority even when the native title-exit event arrives late. Exit restores ordinary link previews; title presses, hiding, removal, and navigation clearing remove the title preview. Both sources preserve encoded URLs and strip invisible control and directional characters.

## Private window lifetime

[[Tests/BrowseTests/BrowserWindowTests.swift#privateWindowLifetime]] verifies isolated in-memory history, cookies, favorites exclusion, temporary site settings, transfer rejection, persistence exclusion, closure cleanup, and preservation of regular history.

## Private window storage sharing

[[Tests/BrowseTests/BrowserWindowTests.swift#privateWindowStorageSharing]] verifies cookies, local storage, and history are shared across panes and tabs within a private window, isolated from other windows, and retained across moves, reloads, and tab closure.

Session storage remains scoped to each page session. Window closure clears its shared website store and history without affecting another private window; a newly opened private window starts empty. Regular browsing cannot see private cookie or storage values.

## Private window keyboard command

[[Tests/BrowseTests/BrowserWindowTests.swift#privateWindowKeyboardCommand]] verifies Command-Shift-N creates a labeled private window with its location popup focused, and closing its final pane closes the sole window.

## Private extension access

[[Tests/BrowseTests/ExtensionTests.swift#privateExtensionAccess]] verifies persisted opt-ins, private-tab queries, script injection, request blocking, revocation, and refusal to supply shared extension configurations to private panes.

The restored host completes an awaited ruleset disable/enable cycle and demonstrates content injection and request blocking before unload. This synchronizes teardown with WebKit’s asynchronous rule loading instead of racing its database callbacks or relying on a fixed delay.

## Private extension iframe isolation

[[Tests/BrowseTests/ExtensionTests.swift#privateExtensionIframeIsolation]] verifies private panes reject extension documents that would let HTTP iframes read or write regular-profile cookies, including after opt-in.

A loopback HTTP iframe first demonstrates both cookie access and writes in an isolated regular profile. The regression then exercises configuration lookup, direct controller navigation, extension tab navigation and creation, lazy page loading, and popup rejection. Private views remain nonpersistent, and the regular cookie store remains unchanged both before and after private-window teardown.

## Native test runner coverage

[[scripts/test-test-runner.py#TestRunnerTests]] verifies full inventory execution, skip accounting, rejection of unmatched filters and ambiguous names, failed-process propagation, timeout termination, and continued execution after failures, crashes, timeouts, or missing results.

## Option-click destinations

[[Tests/BrowseTests/LinkNavigationTests.swift#optionClickDestinations]] verifies that Option-click defaults to a new tab and independently supports new panes and windows, including WebKit actions marked as downloads.

Both navigation callbacks cancel source navigation. Pane placement, sidebar insertion, iframe opener handling, shared-window preference updates, and persistence match the explicit destination. Command-click and Command-Shift-click keep their separate settings.

## Native Option-click links

[[Tests/BrowseTests/LinkNavigationTests.swift#nativeOptionClickLinks]] sends native Option-click events to same-frame, new-window, and iframe links, verifying correct URLs and frame provenance without downloading or navigating the source.

Trusted native clicks must use the isolated document bridge before navigation policy, while page-generated clicks cannot reach it. The fixture requires document and iframe readiness, waits for a rendered snapshot, and converts measured DOM link bounds into native window coordinates before clicking. Failures report DOM mouse events and WebKit navigation-action metadata to distinguish event-delivery problems from routing regressions.

## Link context menu destinations

[[Tests/BrowseTests/LinkContextMenuTests.swift#linkContextMenuDestinations]] invokes WebKit's real context-menu hit testing for main-frame and iframe links and dispatches the resulting pane, tab, and window menu actions.

Open Link in New Tab is first, followed by New Pane and New Window. URLs retain query strings and fragments. Each menu keeps its own target after another menu opens. Copy Link survives and the native window action is replaced. Explicit choices ignore click preferences, preserve the source, place panes adjacent without dedicated-pane reuse, and omit opener metadata for iframe links. New-tab actions preserve selection, pane focus, and zoom, insert directly below the active row, and create a loading controller without mounting the tab.

## Sidebar overflow counts

[[Tests/BrowseTests/SidebarScrollStatusTests.swift#sidebarOverflowCounts]] verifies counts of fully hidden tabs above and below the sidebar viewport, excluding partially visible rows even at fractional scroll positions.

Coverage includes exact row boundaries, the favorites inset, resizing, insertion and removal, overscroll, empty lists, and unmeasured viewports. The top fade remains absent at the start and reaches its maximum after scrolling.

## Option-click shared controller isolation

[[Tests/BrowseTests/LinkNavigationTests.swift#optionClickSharedControllerIsolation]] shares one user-content controller between a routed pane and a plain WebView, verifying only the pane enables Option-click interception and other views cannot route links.

## Application updater isolation

[[Tests/BrowseTests/AppUpdaterTests.swift#applicationUpdaterIsolation]] verifies only packaged production apps are eligible for updates, debug checks are no-ops, and Sparkle’s optional reminder callbacks are registered with their exact selectors.

## Application update feed

[[scripts/test-update-feed.py#UpdateFeedTests]] verifies exact archive/build metadata, escaped release notes, rejection of invalid metadata, and signatures using a public RFC test key on macOS. Tampered archives/feeds and mismatched signing keys are rejected.

The manual verification helper is exercised with a mocked Keychain export and real signing tools, checking one export per run, progress and success output, restrictive permissions, and cleanup after success or key mismatch.

## Application update launch scheduling

[[Tests/BrowseTests/AppUpdaterTests.swift#applicationUpdateLaunchScheduling]] verifies that launch checks respect the ten-minute boundary and recover from missing or future-dated check times.

Recent checks suppress the additional launch request; older checks permit it. [[scripts/test-build-app.sh]] checks that the packaged production app schedules hourly background checks.

## Application update preview

[[Tests/BrowseTests/AppUpdaterTests.swift#applicationUpdatePreview]] exercises debug-only preview eligibility, the pinned Sparkle fixture, real update windows, download cancellation, replay, and the simulated Install and Relaunch action.

The preview uses no updater or installation helper. The test supplies an isolated bundle and intercepts the completion explanation; the running test process survives the final button. Packaging coverage in [[scripts/test-build-app.sh]] verifies opt-in metadata, its removal by normal builds, and rejection of preview production builds.

## Page printing

[[Tests/BrowseTests/PrintingTests.swift#pagePrinting]] dispatches Command-P and File → Print through native menus, verifies the focused pane supplies the job, cancels real print sheets, and checks disabled states without sending anything to a printer.

## Command popup actions

[[Tests/BrowseTests/CommandPopupTests.swift#commandPopupActions]] verifies state-aware actions, favorite and pin changes, split-tab duplication, the native shortcut, filtering, execution, empty results, stale targets, and retention of initial blank tabs.

## Dedicated pane window restoration

[[Tests/BrowseTests/LinkNavigationTests.swift#dedicatedPaneWindowRestoration]] verifies duplicated tabs retain their reusable Command-click destination through full window shutdown and restoration in both main and secondary windows.

The copied destination has a fresh pane identity. After restoring, the next Command-click reuses that pane without increasing the pane count, and the shared dedicated-pane preference remains active.

## Privacy settings migration

[[Tests/BrowseCoreTests/WebsiteSettingsTests.swift#privacySettingsMigration]] verifies version 2 databases retain security and zoom choices with tracking prevention and payment disclosure on and ad measurement off by default. Changed choices persist after reopening.

## Native privacy preferences

[[Tests/BrowseTests/WebsiteSettingsTests.swift#nativePrivacyPreferences]] verifies live native tracking, payment disclosure, and measurement values, advanced navigation protection, unsupported-selector handling, and independent data stores.

These checks verify native configuration, not remote rule availability, relay service access, fingerprint uniqueness, or ad-report delivery. The existing settings toolbar test visits Privacy, and transaction tests include privacy flags in rollback coverage.


## Safari mouse gestures

[[Tests/BrowseTests/ExtensionCompatibilityTests.swift#mouseGesturesSafariSmoke]] optionally imports the app specified by BEND_TEST_MOUSE_GESTURES_APP into isolated storage, verifies settings, and opens a tab with native right-button input.

An injected app lookup and store opener verify the App Store handoff, cancellation, launch failure, and resumption without duplicate imports. The installed package's default leftward gesture uses Safari's favorites URL, which must open Bend's start page. The test never changes the user's installed app or extension preferences.

## Extension permission presentation

[[Tests/BrowseTests/ExtensionPermissionTests.swift#extensionPermissionPresentation]] verifies readable permission summaries, exact website restrictions, unknown-permission visibility, deduplication, and denial when the native dialog is closed.
