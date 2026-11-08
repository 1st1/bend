---
lat:
  require-code-mention: true
---
# Tests

Model, store, and navigation-delegate tests cover pane layouts, persistence, link routing, navigation resolution, and location-popup requests without loading external websites.

Run the test suite and documentation validation from the repository root:

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" swift test --disable-sandbox
lat check
```

## Nested splits and closing

Splitting right and then below preserves leaf order. Closing panes collapses their parent branches, repairs focused-pane identity, and preserves the model’s final pane for the application layer to handle.

## Favicon discovery

[FaviconTests.swift](../Tests/BrowseTests/FaviconTests.swift) verifies relative icon URLs, deduplication, origin fallback, rejected URL schemes, and internal-page exclusion. A local WebKit document checks base URLs and standard icons taking priority over touch icons.

## Extension lifecycle and permissions

[ExtensionTests.swift](../Tests/BrowseTests/ExtensionTests.swift) verifies disabled imports, permission denial and approval, website scope, copied resources, enable/disable behavior, and stable extension identity and grants after restoration.

## Enabled extension restoration

[ExtensionTests.swift](../Tests/BrowseTests/ExtensionTests.swift) recreates the extension host with an isolated persistent profile, verifying enabled state, stable origin, restored grants, and successive storage writes without the original package source.

The fixture unloads runtime contexts without disabling the saved preference. Four iterations read the previous iteration's extension storage, localStorage, and IndexedDB values, including decrypting a fixture ciphertext with a persisted nonextractable WebCrypto key. This exercises host recreation within one test process, not a signed-app upgrade or an authenticated password-manager session.

## Extension startup content injection

[ExtensionTests.swift](../Tests/BrowseTests/ExtensionTests.swift) starts page navigation during extension restoration and verifies content-script injection and request blocking on a local fixture across four host recreations.

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

## Media source selection

[MediaPlayerTests.swift](../Tests/BrowseTests/MediaPlayerTests.swift) checks most-recent playback selection, explicit source selection, commands affecting only that source, persistent dismissal, reappearance on new playback, and cleanup on native-page navigation.

Sources are ordered most-recent-first after playback starts and explicit selection; refreshes, pauses, and metadata changes do not reorder them. With two sources, closing hides the entire panel while retaining both players and their playback state. Refreshing either source or changing metadata keeps it hidden; a new playback start reveals the panel with both players still available.

## Exclusive media playback

[MediaPlayerTests.swift](../Tests/BrowseTests/MediaPlayerTests.swift) starts media in competing panes and windows, checks that older players pause, resumes an older source, and rejects a queued pause for its previous playback revision.

Stopping the new owner must leave older players paused. The HTML fallback fixture separately checks the underlying audio element is paused when another pane starts.

## Sidebar favicons

[FaviconTests.swift](../Tests/BrowseTests/FaviconTests.swift) loads an icon through a local HTTP fixture and checks the mounted sidebar image updates to that exact favicon, resets for a native page, and leaves unvisited tabs uninstantiated.

The mounted icon must stay 16×16 points after loading and across narrow, default, and wide sidebar sizes. An opaque 64-point raster exercises intrinsic-size overflow; `BEND_SIDEBAR_SNAPSHOT` optionally captures the rendered sidebar for visual inspection.

## Live media session smoke test

[MediaPlayerTests.swift](../Tests/BrowseTests/MediaPlayerTests.swift) optionally loads `BEND_MEDIA_SMOKE_URL` in an ephemeral WebKit store, attempts muted playback, matches the sidebar title to Media Session metadata, and tests pause/resume with default playback policy.

This opt-in check uses no saved sign-in and depends on the site's availability, consent flow, and playback policies. Local fixtures cover the deterministic bridge behavior. `BEND_MEDIA_SNAPSHOT` optionally renders the card with multiple players, a long title, and favicon at narrow, default, and wide sidebar widths, plus the full browser window, during the ownership fixture to inspect centered metadata, the compact favicon picker beside transport controls (with a separate row at minimum width), truncation, glass chrome, and pane spacing.

## Floating sidebar interaction

[FloatingSidebarTests.swift](../Tests/BrowseTests/FloatingSidebarTests.swift) exercises edge reveal, hover retention, delayed dismissal, tab selection through native hit testing, pinning, fullscreen edge geometry, and deactivation.

The mounted-window test verifies the canvas frame and retained WebView identities remain unchanged while the panel opens, switches tabs, and closes. The panel reaches the top inset behind the traffic lights, which remain native hit targets. The top-row pin button receives clicks above the pane header; covered pane headers cannot begin a pane drag.

## Build bundle publication

[test-build-app.sh](../scripts/test-build-app.sh) runs the packaging script with isolated compiler and signing stand-ins, verifying failure preservation and replacement without changing an open descriptor to the previous executable.

Signing and verification failures retain the previous bundle and executable inode. Successful publication installs a new inode and removes staging files. The test checks Bend's bundle name and executable, the retained profile identifier, the icon resource and plist entry, HTTP/HTTPS URL-handler and HTML/XHTML document-viewer declarations, and precedence of the new signing override over the legacy override. These checks do not exercise macOS signing or WebKit runtime behavior.

## Catalog download integrity and identity

[ExtensionTests.swift](../Tests/BrowseTests/ExtensionTests.swift) rejects modified, empty, oversized, non-HTTPS, or unsuccessful catalog downloads and mismatched package identities before installation.

A rejected package leaves no installed record or package files. A matching import starts disabled without permission grants; unrelated package identities do not match curated entries.

## Catalog package download smoke test

[ExtensionTests.swift](../Tests/BrowseTests/ExtensionTests.swift) optionally downloads the pinned official 1Password and Dark Reader packages, validates their checksums, and imports each disabled into temporary storage.

Set `BROWSE_TEST_CATALOG_DOWNLOAD=1` to exercise the real catalog network path. The test verifies package identity and version without enabling the extension, opening windows, or touching the user's profile.

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

## Extension privacy settings and restored startup

[ExtensionCompatibilityTests.swift](../Tests/BrowseTests/ExtensionCompatibilityTests.swift) verifies privacy approval, persistent grants, disabled saver settings, callback errors, revocation, and startup calls gated on saved configuration across host recreations.

The fixture stores a configured flag before restarting its host, then uses the password-saving and autofill settings during background startup before answering messages. It uses no credentials or real vault. Unsupported enabling is rejected rather than claiming to implement a built-in saver.

## Extension document authentication round trip

[ExtensionCompatibilityTests.swift](../Tests/BrowseTests/ExtensionCompatibilityTests.swift) verifies that same-tab extension-to-website-to-extension navigation preserves session storage and tab identity without giving the website extension privileges.

A local website cannot read the extension's session storage, call the compatibility bridge, or authorize its own return to a privileged document. An explicit extension tab update returns to the retained view with the original setup marker; the flow creates no extra browser pane. Navigation triggers use synchronous JavaScript evaluation so the test does not depend on an injected async function surviving a document transition.

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

The test uses local HTTP fixtures and ephemeral storage in a full-content window with a unified toolbar. It checks that the titlebar adds no extra top inset. Narrowing and widening columns verifies CSS viewport width matches the native web view, media queries switch layouts, and resize events fire. Both the HTTP request received by the fixture and JavaScript expose Safari-compatible product tokens plus Bend’s identifier. Unvisited tabs remain uncreated, hidden tabs keep their viewport and ignore other tabs' zoom, selection resizes the active host, and tab or background-pane closure removes retained content.

After switching back beneath a later-mounted hidden tab, the test verifies the inactive hosting root rejects hit tests and each visible pane's center resolves to its web view in None, Transparency, Outline, Outline glow, and Title tint modes. Switching highlight styles preserves the same WebView and native parent. On macOS 26 and later, the web surface reaches the pane’s top edge without a border inset. The test also sends a complete mouse gesture through the window: header press, drag across nine interior points of a real web view, and release. Each point activates the target preview; release rearranges the panes and removes the drag surface while preserving native WebKit parents, document identity, and unsaved input.

## Pane drop layout moves

[PaneDropTests.swift](../Tests/BrowseCoreTests/PaneDropTests.swift) checks every source, target, and edge combination in a nested layout, preserving all pane IDs and unrelated split fractions while rejecting missing or identical endpoints.

## Cross-tab pane transfer model

[PaneTransferTests.swift](../Tests/BrowseCoreTests/PaneTransferTests.swift) checks transfers at all four edges across workspaces, source collapse, empty-workspace recovery, detaching, invalid moves, and valid session restoration.

Moving a designated Command-click pane clears the source tab’s designation and does not claim an ordinary pane in the destination.

## Cross-tab native pane dragging

[PaneTransferTests.swift](../Tests/BrowseTests/PaneTransferTests.swift) drives a single-pane tab through sidebar hover into an unvisited tab, drops on its WebKit content, then detaches into sidebar space.

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

Header hit testing reaches the compact title handles, which drive hover feedback and pane dragging. Mouse-down focuses the pane; small motion does not move the window or begin a drag, and mouse-up clears tracking. Empty header and sidebar backgrounds request native window dragging. Tab rows, toolbar controls, sidebar resize handles, and traffic lights are excluded; native clicks still activate the sidebar toggle without creating a tab.

Every background window-drag request must originate inside AppKit's normal event dispatch, so activating clicks cannot skip native window appearance bookkeeping. Outside mouse-down dispatch the background targets do not claim hit testing, preserving underlying scroll and hover behavior.

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

## Pane geometry and insertion

[PaneGeometryTests.swift](../Tests/BrowseCoreTests/PaneGeometryTests.swift) verifies stable pane identities and exact frames through horizontal and nested vertical splits. Unaffected branches keep their frames, and closing restores the previous geometry.

## Pane geometry bounds

[PaneGeometryTests.swift](../Tests/BrowseCoreTests/PaneGeometryTests.swift) verifies that small viewports grow to fit minimum pane sizes, divider gaps remain consistent, and drag fractions respect both branches' bounds.

## Divider pointer tracking

[PaneResizingTests.swift](../Tests/BrowseTests/PaneResizingTests.swift) sends real window mouse events through horizontal and vertical dividers in an offscreen browser layout.

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

The allowed range is 200–400 points with a 250-point default. Existing in-range widths remain unchanged; out-of-range widths clamp and nonfinite stored values use the default.

## Sidebar visibility animation

[PaneResizingTests.swift](../Tests/BrowseTests/PaneResizingTests.swift) samples native canvas geometry during sidebar collapse and restoration, checking intermediate positions, final bounds, reversal, and unchanged live WebView/controller identity.

Disabling animations applies the final layout immediately without intermediate frames.

## Native sidebar tab dragging

[PaneTransferTests.swift](../Tests/BrowseTests/PaneTransferTests.swift) sends window mouse events through the glass sidebar to verify repeated tab reordering, stable insertion targets, Escape and outside cancellation, selection, recovery from a missing release, and separate close-button handling.

## Pane transfer round trips

[PaneTransferTests.swift](../Tests/BrowseTests/PaneTransferTests.swift) moves the same live pane between two surviving tabs 24 times per layout, using normal and scrolling layouts to check the third drag and later round trips.

The first twenty transfers in each layout hover to select the destination before dropping onto a pane; the remainder drop directly onto the tab row. Each press must reach exactly one visible handle with current tab ownership. The window must consume every mouse event in that gesture and return to idle after release. Synthetic window events verify retained page controllers, document tokens, unsaved form contents, and unique model ownership while both tab trees remain mounted.

## Native extension messaging

[ExtensionCompatibilityTests.swift](../Tests/BrowseTests/ExtensionCompatibilityTests.swift) exercises real WebKit native-message calls with an isolated Python echo helper, including restoration, revocation, disconnects, and invalid frames.

One-shot and persistent messages cross the delegate boundary and handle fragmented JSON replies. Recreated managers restore permission and reconnect; permission denial and context teardown empty the connection registry. Host crashes and oversized frames reject promises. Unit checks cover Unicode, concatenated frames, manifest allowlists, missing hosts, and traversal rejection. The opt-in Firefox onboarding smoke verifies the real 1Password package requests its registered helper, while an injected resolver prevents access to the user's desktop vault. Touch ID and authenticated desktop unlocking require a separate manual test.

## Extension diagnostic logging

[ExtensionCompatibilityTests.swift](../Tests/BrowseTests/ExtensionCompatibilityTests.swift) verifies diagnostic persistence across logger instances, bounded rotation, owner-only files, safe error categories, and a memory fallback when disk writes fail.

Native-message integration checks require request, resolution, launch, first-send/receive, disconnect, rejection, and exit events, while excluding fixture payloads and Gecko IDs. An extension-page error containing a synthetic secret must emit only its category and error type; arbitrary categories are rejected. These diagnostics do not assert that the user's 1Password account or desktop handshake succeeds.

## 1Password protocol diagnostic redaction

[ExtensionCompatibilityTests.swift](../Tests/BrowseTests/ExtensionCompatibilityTests.swift) verifies that native response summaries expose only known protocol types and error names, never arbitrary response fields or synthetic account secrets.

Success contents are excluded entirely, unknown enum values become a generic label, recognized failure names survive redaction without callback IDs or error prose, and browser identities are decoded only from the protocol's browser_state field with bounded identifier validation. These unit checks do not establish desktop authentication or Touch ID compatibility.

## Configurable link destination

[LinkNavigationTests.swift](../Tests/BrowseTests/LinkNavigationTests.swift) verifies live Command-click destination changes on an existing controller, adjacent placement, source preservation, ordinary new-window behavior, and main-frame opener tracking.

## UI preference persistence

[AddressRequestTests.swift](../Tests/BrowseTests/AddressRequestTests.swift) verifies legacy session defaults, preference persistence across store recreation, preserved tab identity, and numeric bounds and nonfinite-value handling.

Window/header glass preferences persist independently, preserve legacy defaults, and support resetting both appearances. Separator settings also round-trip their enabled state, color, opacity, and width, use defaults for older sessions, normalize invalid values, and reset independently of highlight styles.

Highlight settings preserve separate colors, width, intensity, spread, and mode across restart, including None mode and retained title-tint color and intensity; absent highlight settings use None. Older records without spread decode with their previous intensity-derived radius; records without title-tint fields receive the default color and intensity. Invalid colors and nonfinite numeric values normalize to defaults, and out-of-range values are bounded.

## Home page suggestion ranking

[HistoryTests.swift](../Tests/BrowseCoreTests/HistoryTests.swift) reproduces a deep link with one learned choice competing with 35 home-page visits. Host prefixes prefer the home page, path searches retain deep links, and frequent visits can outweigh learned choices.

Bare-host prefixes also prefer a www. home page over a much more frequently visited article; omitting www. from a path query still finds and completes the deep link.

## Remove address suggestion

[HistoryStoreTests.swift](../Tests/BrowseTests/HistoryStoreTests.swift) exercises a popup row’s removal button and verifies immediate result refresh, persisted removal of visits and learned choices, and no navigation.

## Live window glass preferences

[AddressRequestTests.swift](../Tests/BrowseTests/AddressRequestTests.swift) verifies style and tint update on the existing native window glass, header changes leave it alone, and reset clears tint without replacing content.

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

## Tab merge placement

[PaneTransferTests.swift](../Tests/BrowseCoreTests/PaneTransferTests.swift) checks all four merge edges, intact source trees, untouched destination branches and fractions, focus, title, persistence, and atomic rejection of stale or foreign target panes.

## Tab drag hover and merge placement

[PaneTransferTests.swift](../Tests/BrowseTests/PaneTransferTests.swift) drives native tab drags through delayed selection and all four pane-edge merges, checking timer cancellation, zoom exit, preview cleanup, and preservation of live page and extension identities.

## Canceling new tab entry

[AddressRequestTests.swift](../Tests/BrowseTests/AddressRequestTests.swift) verifies that canceling initial blank-tab or split-pane entry restores the previous focus, layout, and zoom without recording a closed item.

Both split directions restore a non-first source pane, preserve its controller, and dispose of the provisional controller. The saved session excludes canceled panes and tabs; a pane that has navigated is retained. Existing tabs, completed entry, tabs with added panes, and tabs opened with a destination cannot be discarded through this path.

## New tab popup keyboard cancellation

[AddressRequestTests.swift](../Tests/BrowseTests/AddressRequestTests.swift) exercises Escape and Command-W through the native popup and application menu after creating a tab or using Command-D and Shift-Command-D.

Both commands dismiss the popup and remove the initial blank pane or tab even after unsubmitted editing. Existing-pane Escape, outside dismissal, and successful submission retain their content. The placeholder explicitly uses light-gray text.

## Dedicated Command-click pane

[LinkNavigationTests.swift](../Tests/BrowseTests/LinkNavigationTests.swift) verifies one reusable link destination per tab, including stable pane and WebView identity across repeated links.

Clicks from different source panes reuse the target, independent tabs receive independent targets, and iframe/self links avoid stale or self-referential openers. Closing, reopening, replacing, restarting, and switching settings preserve the intended designation and page counts. Closing all ordinary panes promotes the surviving destination without replacing its WebView; the next link creates a new reusable target. Legacy single-pane designations are cleared on restoration.

## Command-click preference migration

[LinkNavigationTests.swift](../Tests/BrowseTests/LinkNavigationTests.swift) verifies that both legacy link-opening choices survive loading and that the dedicated-pane choice persists without replacing existing tabs.

## Page zoom shortcuts

[PageZoomTests.swift](../Tests/BrowseTests/PageZoomTests.swift) invokes native menu shortcuts against two web panes to verify zoom-in aliases, zoom-out, reset, focused-pane isolation, bounds, and disabled internal or hidden pages.

Changing page zoom preserves the document and form contents and leaves the independent pane-maximizing layout mode untouched. Native magnification is enabled, scales only one pane, and remains independent of keyboard page zoom. The test applies magnification through WebKit’s public API; physical trackpad gesture delivery requires a manual check.

## Find in page

[FindInPageTests.swift](../Tests/BrowseTests/FindInPageTests.swift) exercises the Command-F menu against real WebKit documents, checking focused-pane routing, case-insensitive matches, next/previous wrapping, scrolling, header clearance, Escape dismissal, and disabled internal-page commands.

Actual window mouse clicks on the shared-style find buttons navigate forwards and backwards and dismiss the bar, clearing highlights and returning focus to the web page.

Layout assertions verify that the input keeps its frame across empty, pending, matching, and zero-result states, including at minimum pane width. Empty focused and cleared input keep the caret beyond the search icon and vertically inside the field, including at minimum width. The count stays right-aligned inside the field without overlapping the native text editor. Return and Find Next retain the count while navigating; editing the query immediately clears the old total.

On macOS 26 and later, the find controls share the native title glass without a separate material. Opening and closing adjust the glass height and WebKit inset together; style and tint changes preserve the field editor and control parentage. Active-pane tint spans the combined header, covers the find row, stays absent from inactive panes, and clears without removing the controls.

Match-count assertions cover case-insensitive totals, hidden-text exclusion, zero and empty queries, and matches inside an iframe. Dismissal checks clear main-frame and iframe selections, preserve scroll, and reject late count results; reopening searches the retained query again. Repeated Escape presses after dismissal still reach page key listeners without crashing. Cancellation is also safe with no bar or before mounting a web view.

## Settings close shortcut

[BrowserWindowTests.swift](../Tests/BrowseTests/BrowserWindowTests.swift) verifies Command-W closes the focused Settings window without changing browser panes, still closes a focused browser pane, and cancels a new tab from its address popup.

The native Settings window hides the centered window title and keeps full-size content, with a transparent titlebar before content scrolls beneath the section heading.

## Settings section toolbar

[BrowserWindowTests.swift](../Tests/BrowseTests/BrowserWindowTests.swift) verifies that the native Settings toolbar contains the section title and that sidebar selection updates the window title for UI, Websites, Extensions, and Development.

The toolbar test verifies reopening centers Settings on each available screen after moving it offscreen. It scrolls overflowing detail content beneath the stationary title and back to the top, checking that native titlebar transparency changes with the overlap. It also verifies native toolbar insets and fixed width bounds across all sections while allowing vertical resizing. The sidebar stays 200 points wide across section changes, including attempts to move the native divider in both directions.

## Pane-centered location popup

[AddressRequestTests.swift](../Tests/BrowseTests/AddressRequestTests.swift) verifies that location popups center horizontally on their target pane, start one-fifth down it, and retain their initial top edge while open.

The native-view regression covers separate left/right targets, result growth and shrinkage, validation errors, pane resizing and clipping, fresh placement after reopening, and retaining the fallback top when a pane mounts later.

## Website setting identity

[WebsiteSettingsTests.swift](../Tests/BrowseCoreTests/WebsiteSettingsTests.swift) verifies hostname normalization, path/scheme/port sharing, distinct subdomains, internal-page exclusion, and valid zoom bounds.

## Website settings transactions

[WebsiteSettingsTests.swift](../Tests/BrowseCoreTests/WebsiteSettingsTests.swift) verifies default and override persistence, atomic rollback after an injected write failure, retry, deletion, and invalid-value rejection.

## Website settings storage protection

[WebsiteSettingsTests.swift](../Tests/BrowseCoreTests/WebsiteSettingsTests.swift) verifies corrupt files are preserved and unrelated or newer databases are rejected without adopting their contents.

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

The bitmap checks also verify that glow colors only the focused pane’s shadow, follows focus changes, respects intensity and spread, and leaves both pane interiors clear. Leaving glow mode restores the ordinary black shadow.

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

[BrowserWindowTests.swift](../Tests/BrowseTests/BrowserWindowTests.swift) compares actual native traffic-light frames with pane-title centers, verifying alignment and unchanged button geometry across repeated sidebar toggles and window resizing.

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

Pointer movement within one link switches the preview to the right and back without duplicate URL messages or oscillation. Long URLs truncate clear of the cursor at either edge, including after a pane resize.

## Developer tools

[DeveloperToolsTests.swift](../Tests/BrowseTests/DeveloperToolsTests.swift) opens the native inspector through the Develop menu shortcut and checks that console errors, thrown errors, and unhandled rejections from the selected pane reach its console.

Two mounted pages verify source isolation and focused-pane routing. Command-Shift-I toggles the inspector below its page in the same pane. The native toolbar switches between right and bottom docking without losing console messages, and its close button removes the panel. Inspecting a real DOM element before docking, plus a repeated native reveal in a narrow page, must keep the frontend in its original panel and window with no empty dock region. Mouse drags resize both dock positions without moving the browser window. Reopening and find-bar coexistence preserve separate page/inspector bounds, including narrow panes. The inspector control bridge is absent from the inspected website. Left docking and detaching stay hidden; closure removes the frontend, and commands disable on native Bend pages. `BEND_INSPECTOR_SNAPSHOT` optionally captures the containing browser window. Run this AppKit test without parallel execution because it owns the shared application menu.
