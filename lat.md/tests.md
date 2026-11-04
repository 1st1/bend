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

## Catalog download integrity and identity

[ExtensionTests.swift](../Tests/BrowseTests/ExtensionTests.swift) rejects modified, empty, oversized, non-HTTPS, or unsuccessful catalog downloads and mismatched package identities before installation.

A rejected package leaves no installed record or package files. A matching import starts disabled without permission grants; unrelated package identities do not match curated entries.

## Catalog package download smoke test

[ExtensionTests.swift](../Tests/BrowseTests/ExtensionTests.swift) optionally downloads the pinned official 1Password package, validates its checksum, and imports it disabled into temporary storage.

Set `BROWSE_TEST_CATALOG_DOWNLOAD=1` to exercise the real catalog network path. The test verifies package identity and version without enabling the extension, opening windows, or touching the user's profile.

## Extension content injection and blocking

[ExtensionTests.swift](../Tests/BrowseTests/ExtensionTests.swift) loads a local HTTP fixture in real WebKit, verifies content injection and declarative blocking, then checks both disappear after disable/reload. It also verifies pane registration and active-tab changes.

## Extension compatibility permissions and notifications

[ExtensionCompatibilityTests.swift](../Tests/BrowseTests/ExtensionCompatibilityTests.swift) verifies native messaging survives the adapters, notification IDs are isolated, callbacks report errors, permission revocation is enforced, and websites cannot call the bridge.

An injected notification backend exercises create, enumeration, click routing, clear, and disable cleanup without displaying system notifications or changing system authorization. The fixture uses its own ephemeral website data store.

## Extension created navigation events

[ExtensionCompatibilityTests.swift](../Tests/BrowseTests/ExtensionCompatibilityTests.swift) verifies a main-frame link opening emits a navigation-target event with the real WebKit tab ID while native tab events still arrive.

Unrelated tab creation and subframe openings do not produce a fabricated main-frame event. URL filtering is exercised with the fixture destination.

## Embedded extension pages and tab transitions

[ExtensionCompatibilityTests.swift](../Tests/BrowseTests/ExtensionCompatibilityTests.swift) verifies embedded extension messaging and website-to-extension tab updates with local, account-free fixtures.

A declared web-accessible iframe communicates with its background, while a private resource cannot run in the website. Website-initiated top-level extension navigation is rejected. An extension's tab update loads its own document with the same tab identity; a saved pane restores after its extension loads. Disabling tears down that document, and following a web URL returns to an ordinary view without privileged extension APIs.

## Firefox onboarding smoke test

[ExtensionCompatibilityTests.swift](../Tests/BrowseTests/ExtensionCompatibilityTests.swift) optionally loads a real Firefox 1Password package through Browse's production extension manager in an isolated, windowless profile.

Set `BROWSE_TEST_FIREFOX_PACKAGE` to a local official XPI to run this network-dependent test. It verifies action-driven onboarding, declines the three optional onboarding choices in disposable data, and follows Sign in to the official account page's email form. The website view has a normal pane-sized viewport even though no window is displayed. It enters no credentials and does not establish authenticated sign-in, desktop-app integration, autofill, or account persistence. Without the environment variable, this smoke test returns without loading a real package.

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

## Divider bounds

Divider updates clamp fractions to safe bounds and leave unrelated split nodes unchanged, preventing extreme drag values from making persisted panes disappear.

## Address resolution

Hostnames, explicit HTTPS, localhost, internal start pages, and search queries resolve correctly. Empty input and explicit non-web URL schemes are rejected, and query punctuation survives URL encoding.

## Location popup requests

[AddressRequestTests.swift](../Tests/BrowseTests/AddressRequestTests.swift) verifies that explicit location requests target the chosen pane, new blank panes prompt after focus changes, and link destinations do not prompt. Invalid pane IDs are ignored.

The store tests use an isolated temporary session-file path. They cover both split directions, blank tabs, new workspaces, and the replacement tab created after closing a workspace's last tab. Each automatic request must identify the newly focused pane.

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
