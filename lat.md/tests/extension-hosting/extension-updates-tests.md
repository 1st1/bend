---
lat:
  require-code-mention: true
---
# Extension updates tests

Tests verify owned extension packages, update checks, and resource migration.

See [[lat.md/architecture/extensions/extension-updates|Architecture and behavior]].

## uBlock origin migration and isolation

[[Tests/BrowseTests/ExtensionTests.swift#uBlockOriginMigrationAndIsolation]] checks that uBlock Lite receives a Safari-style origin while preserving saved extension settings and keeping unrelated packages on their original scheme.

The test uses a Safari extension bundle fixture to seed native extension storage under the old origin, restores the same installed record, and verifies settings, UUID, enablement, compatibility-bridge access, and a saved page URL including its query. A lookalike display name with another package identity does not opt into the override. The opt-in [[lat.md/tests/extension-hosting/compatibility-tests#Safari uBlock Lite compatibility]] test verifies the real Safari package's browser detector, popup controls, and request blocking.

## Extension update permissions and resource pages

[ExtensionTests.swift](../../../Tests/BrowseTests/ExtensionTests.swift) verifies extension pages load with their API namespace and stable identity. An updated extension requesting a new website stays unloaded until its additional access is approved.

The resource-page fixture explicitly permits WebAssembly in its content security policy, instantiates a minimal module, and writes and reads IndexedDB data. This checks the host's runtime primitives independently of third-party startup and native messaging; it does not establish 1Password compatibility.

## Owned extension packages and updates

[ExtensionTests.swift](../../../Tests/BrowseTests/ExtensionTests.swift) verifies XPI copies survive source removal, replacements preserve origin and storage, invalid or mismatched updates retain the installed version, and new permissions require approval.

Restoration retains the pending approval state. Uninstallation removes managed files while preserving the original package folder.

Storage retention runs in a unique persistent WebKit configuration, separate from the user's profile. Nonpersistent contexts are unsuitable for asserting storage across context replacement because their ephemeral storage is discarded on unload.

## Extension package migration and isolation

[ExtensionTests.swift](../../../Tests/BrowseTests/ExtensionTests.swift) verifies migration retains identity and grants, owned copies restore after source removal, internal links remain usable, and external symbolic links are rejected.

## Extension update metadata

[[Tests/BrowseTests/ExtensionUpdateTests.swift#extensionUpdateMetadata]] verifies Mozilla package metadata and GitHub release-page parsing, including exact Safari asset/checksum association, duplicate or missing assets, foreign hosts, invalid tags, changed markup, and numeric version comparisons.

## Automatic extension updates

[[Tests/BrowseTests/ExtensionUpdateTests.swift#automaticExtensionUpdates]] exercises manual and scheduled checks, request coalescing, persisted preferences, explicit and automatic installation, permission review, failure retention, and removal during download.

Fixtures use isolated extension storage and injected network boundaries. Scheduling checks cover the four-hour interval, persisted results and failures reused on startup, restored update candidates, explicit checks bypassing the cache, and future-dated cache rejection. The installed extension retains its origin, and downloads run without holding the manager’s mutation lock. [[lat.md/tests/extension-hosting/extension-updates-tests#Owned extension packages and updates]] separately verifies native storage preservation and transaction rollback.

## Extension update service smoke test

[[Tests/BrowseTests/ExtensionUpdateTests.swift#extensionUpdateServiceSmoke]] optionally queries the official release pages or APIs and downloads each published package with digest validation, without installing it or modifying the user profile.

Set `BROWSE_TEST_EXTENSION_UPDATES=1` to enable all live network checks, or supply comma-separated catalog IDs to select sources. Public-service rate limits remain real failures; no application credentials are used.

## Safari direct-download migration

[[Tests/BrowseTests/UBlockLiteTests.swift#safariUBlockDirectMigration]] replaces the real Safari bundle with its official release ZIP in isolated persistent storage and verifies UUID, origin, enablement, saved data, and restoration.

Set `BROWSE_TEST_UBLOCK_SAFARI_PACKAGE` to the ZIP and `BROWSE_TEST_UBLOCK_SAFARI_PREVIOUS` to the app extension bundle. The package contents remain unmodified, and [[lat.md/tests/extension-hosting/compatibility-tests#Safari uBlock Lite compatibility]] additionally exercises detection and request blocking with the ZIP.
