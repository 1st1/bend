---
lat:
  require-code-mention: true
---
# Tests

Model, store, and navigation-delegate tests cover pane layouts, persistence, link routing, navigation resolution, and location-popup requests without loading external websites.

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

## Build bundle publication

[test-build-app.sh](../scripts/test-build-app.sh) runs the packaging script with isolated compiler and signing stand-ins, verifying failure preservation and replacement without changing an open descriptor to the previous executable.

Signing and verification failures retain the previous bundle and executable inode. Successful publication installs a new inode and removes staging files; these checks do not exercise macOS signing or WebKit runtime behavior.

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

[ExtensionCompatibilityTests.swift](../Tests/BrowseTests/ExtensionCompatibilityTests.swift) optionally loads a real Firefox 1Password package through Browse's production extension manager in an isolated, windowless profile.

Set `BROWSE_TEST_FIREFOX_PACKAGE` to a local official XPI to run this network-dependent test. It verifies action-driven onboarding, declines three optional choices in disposable data, and follows Sign in to the official email form in the same logical tab. An extension-authorized return reuses the original view and skips the already-answered choices. It enters no credentials and does not establish authenticated sign-in, desktop integration, autofill, or account persistence. Without the environment variable, it returns without loading a real package.

## Extension privacy settings and restored startup

[ExtensionCompatibilityTests.swift](../Tests/BrowseTests/ExtensionCompatibilityTests.swift) verifies privacy approval, persistent grants, disabled saver settings, callback errors, revocation, and startup calls gated on saved configuration across host recreations.

The fixture stores a configured flag before restarting its host, then uses the password-saving and autofill settings during background startup before answering messages. It uses no credentials or real vault. Unsupported enabling is rejected rather than claiming to implement a built-in saver.

## Extension document authentication round trip

[ExtensionCompatibilityTests.swift](../Tests/BrowseTests/ExtensionCompatibilityTests.swift) verifies that same-tab extension-to-website-to-extension navigation preserves session storage and tab identity without giving the website extension privileges.

A local website cannot read the extension's session storage, call the compatibility bridge, or authorize its own return to a privileged document. An explicit extension tab update returns to the retained view with the original setup marker; the flow creates no extra browser pane. Navigation triggers use synchronous JavaScript evaluation so the test does not depend on an injected async function surviving a document transition.

## Dark Reader compatibility smoke test

[DarkReaderTests.swift](../Tests/BrowseTests/DarkReaderTests.swift) exercises the official Firefox Dark Reader package through Browse's production extension host with temporary storage and a local HTTP page.

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

[FaviconTests.swift](../Tests/BrowseTests/FaviconTests.swift) verifies that invalid image data falls through to the next candidate and cancellation discards a successful response before it can update the pane.

## Favicon navigation reset

[FaviconTests.swift](../Tests/BrowseTests/FaviconTests.swift) verifies that a provisional navigation or opening an internal page clears the previous site's favicon.

## Link pane placement

Opening a link splits its source pane to the right even when another pane is focused, preserves neighboring branches and the source URL, and focuses the destination. The result survives serialization; missing source panes leave the tab unchanged.

## Command-click navigation

[LinkNavigationTests.swift](../Tests/BrowseTests/LinkNavigationTests.swift) verifies that WebKit's Command-left-click action opens a pane and cancels source navigation. Ordinary clicks, other buttons, and scripted navigation do not open panes; custom schemes remain blocked.

## Command-click new-window links

[LinkNavigationTests.swift](../Tests/BrowseTests/LinkNavigationTests.swift) verifies that Command-clicking a new-window link opens a pane without creating a tab. An ordinary new-window link still creates a tab.

## Mounted tab switching

[TabSwitchingTests.swift](../Tests/BrowseTests/TabSwitchingTests.swift) switches between real offscreen WebKit tabs and verifies native parents, document identity, unsaved input, and scroll position survive.

The test uses local HTTP fixtures and ephemeral storage in a full-content window with a unified toolbar. It checks that the titlebar adds no extra top inset. Narrowing and widening columns verifies CSS viewport width matches the native web view, media queries switch layouts, and resize events fire. Both the HTTP request received by the fixture and JavaScript expose Safari-compatible product tokens plus Browse’s identifier. Unvisited tabs remain uncreated, hidden tabs keep their viewport and ignore other tabs' zoom, selection resizes the active host, and tab or background-pane closure removes retained content.

After switching back beneath a later-mounted hidden tab, the test verifies the inactive hosting root rejects hit tests and each visible pane's center resolves to its web view. The test also sends a complete mouse gesture through the window: header press, drag across nine interior points of a real web view, and release. Each point activates the target preview; release rearranges the panes and removes the drag surface while preserving native WebKit parents, document identity, and unsaved input.

## Pane drop layout moves

[PaneDropTests.swift](../Tests/BrowseCoreTests/PaneDropTests.swift) checks every source, target, and edge combination in a nested layout, preserving all pane IDs and unrelated split fractions while rejecting missing or identical endpoints.

## Cross-tab pane transfer model

[PaneTransferTests.swift](../Tests/BrowseCoreTests/PaneTransferTests.swift) checks transfers at all four edges across workspaces, source collapse, empty-workspace recovery, detaching, invalid moves, and valid session restoration.

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

Header hit testing reaches both the compact title handle and the adjacent empty-space handle; only the title handle drives hover feedback. Mouse-down focuses its pane and starts tracking; small motion does not move the window or begin a drag, and mouse-up clears tracking.

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

Repeated pointer coordinates, forward movement, reversals, and release must preserve the expected pane size without feedback from the divider’s changing position. Axis cases run sequentially because they share native mouse-gesture state.

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

## History ranking and learned choices

[HistoryTests.swift](../Tests/BrowseCoreTests/HistoryTests.swift) verifies recency, frequency, learned query choices, URL matching, and result limits so suggestions remain relevant and bounded.

## History removal and bounds

[HistoryTests.swift](../Tests/BrowseCoreTests/HistoryTests.swift) verifies eviction at the visit limit, removal from suggestions, and clearing visits and learned choices while retaining a valid model.

## History persistence and clearing

[HistoryStoreTests.swift](../Tests/BrowseTests/HistoryStoreTests.swift) verifies that visits and learned choices survive reloading, and that removal and clearing persist independently of session data.

## Unreadable history preservation

[HistoryStoreTests.swift](../Tests/BrowseTests/HistoryStoreTests.swift) verifies that corrupt history is reported and preserved during ordinary saves. Explicit clearing permits a valid empty history file to replace it.

## Completed navigation history

[HistoryStoreTests.swift](../Tests/BrowseTests/HistoryStoreTests.swift) checks that completed web navigation records once, title changes update existing history, and later URL changes add visits. Failed navigation and internal pages are excluded.

## Flat tab list restoration

[ReopenTests.swift](../Tests/BrowseTests/ReopenTests.swift) verifies legacy groups merge in order without losing selection, pane identities, layouts, or URLs. New tabs append to the list; close/reopen and saving preserve the single-group session.

## Sidebar tab reordering

[ReopenTests.swift](../Tests/BrowseTests/ReopenTests.swift) exercises upward and downward tab moves, invalid and redundant drops, unchanged selection and live views, and persistence of tab order and pane layouts.

## Sidebar resize tracking and restoration

[PaneResizingTests.swift](../Tests/BrowseTests/PaneResizingTests.swift) drives the sidebar edge in a native window, checking repeated pointer positions, reversals, bounds, repeated drags, pane resizing, live controllers, hide/show, and saved-width restoration.

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

Window/header glass preferences persist independently, preserve legacy defaults, and support resetting both appearances.

## Home page suggestion ranking

[HistoryTests.swift](../Tests/BrowseCoreTests/HistoryTests.swift) reproduces a deep link with one learned choice competing with 35 home-page visits. Host prefixes prefer the home page, path searches retain deep links, and frequent visits can outweigh learned choices.

## Remove address suggestion

[HistoryStoreTests.swift](../Tests/BrowseTests/HistoryStoreTests.swift) exercises a popup row’s removal button and verifies immediate result refresh, persisted removal of visits and learned choices, and no navigation.

## Live window glass preferences

[AddressRequestTests.swift](../Tests/BrowseTests/AddressRequestTests.swift) verifies style and tint update on the existing native window glass, header changes leave it alone, and reset clears tint without replacing content.

## Joining tab layouts

[PaneTransferTests.swift](../Tests/BrowseCoreTests/PaneTransferTests.swift) verifies joins preserve both split trees, page identities, destination title, and source focus, remove the source tab, and survive serialization.

Same-workspace and cross-workspace joins retain valid sessions, including replacement of an emptied workspace. Self-joins and missing endpoints leave the session unchanged.

## Independent browser windows

[BrowserWindowTests.swift](../Tests/BrowseTests/BrowserWindowTests.swift) checks independent tabs and address panels, shared history updates and preferences, live glass propagation, and preservation of the other window's controllers and extension adapters on close.

## Browser window restoration

[BrowserWindowTests.swift](../Tests/BrowseTests/BrowserWindowTests.swift) verifies per-window layouts and selection survive quit, closing one window removes it from restoration, final-window closure preserves it, and preferences persist after the primary closes.

The test also closes every registered extension window and opens a new one, checking that retired adapters stay detached and the shared manager registers the new window correctly.

## New window keyboard command

[BrowserWindowTests.swift](../Tests/BrowseTests/BrowserWindowTests.swift) dispatches Command-N through the native menu, checks that it creates a separate blank browser window, and verifies tab commands follow focus between both windows.
