---
lat:
  require-code-mention: true
---
# Extension catalog and settings tests

Tests verify curated extension installation and native extension settings windows.

See [[lat.md/architecture/extensions/catalog|Architecture and behavior]].

## Curated extension settings pages

[[Tests/BrowseTests/ExtensionTests.swift#curatedExtensionSettingsPages]] verifies settings routes for 1Password and Dark Reader without options declarations, declared-page precedence, identity isolation, enablement, native storage, window reuse, and cleanup.

## Curated extension settings smoke test

[[Tests/BrowseTests/ExtensionTests.swift#curatedExtensionSettingsSmoke]] optionally imports official 1Password and Dark Reader packages into disposable storage and verifies that their settings routes render controls without a manifest options declaration.

Set `BROWSE_TEST_FIREFOX_PACKAGE` and/or `BROWSE_TEST_DARK_READER_PACKAGE` to local package paths. The test enters no credentials and does not use existing extension storage.

## Catalog download integrity and identity

[ExtensionTests.swift](../../../Tests/BrowseTests/ExtensionTests.swift) rejects modified, empty, oversized, non-HTTPS, or unsuccessful catalog downloads and mismatched package identities before installation.

A rejected package leaves no installed record or package files. A matching import starts disabled without permission grants; unrelated package identities do not match curated entries.

## Catalog package download smoke test

[ExtensionTests.swift](../../../Tests/BrowseTests/ExtensionTests.swift) optionally downloads the pinned official 1Password and Dark Reader packages, validates their checksums, and imports each disabled into temporary storage.

Set `BROWSE_TEST_CATALOG_DOWNLOAD=1` to exercise the real catalog network path. The test verifies package identity and version without enabling the extension, opening windows, or touching the user's profile.
