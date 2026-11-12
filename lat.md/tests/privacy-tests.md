---
lat:
  require-code-mention: true
---
# Privacy tests

Tests verify private browsing lifetimes, storage isolation, and privacy preferences.

See [[lat.md/architecture/privacy|Architecture and behavior]].

## Private window lifetime

[[Tests/BrowseTests/BrowserWindowTests.swift#privateWindowLifetime]] verifies isolated in-memory history, cookies, favorites exclusion, temporary site settings, transfer rejection, persistence exclusion, closure cleanup, and preservation of regular history.

## Private window storage sharing

[[Tests/BrowseTests/BrowserWindowTests.swift#privateWindowStorageSharing]] verifies cookies, local storage, and history are shared across panes and tabs within a private window, isolated from other windows, and retained across moves, reloads, and tab closure.

Session storage remains scoped to each page session. Window closure clears its shared website store and history without affecting another private window; a newly opened private window starts empty. Regular browsing cannot see private cookie or storage values.

## Private window keyboard command

[[Tests/BrowseTests/BrowserWindowTests.swift#privateWindowKeyboardCommand]] verifies Command-Shift-N creates a labeled private window with its location popup focused, and closing its final pane closes the sole window.

## Privacy settings migration

[[Tests/BrowseCoreTests/WebsiteSettingsTests.swift#privacySettingsMigration]] verifies version 2 databases retain security and zoom choices with tracking prevention and payment disclosure on and ad measurement off by default. Changed choices persist after reopening.

## Native privacy preferences

[[Tests/BrowseTests/WebsiteSettingsTests.swift#nativePrivacyPreferences]] verifies live native tracking, payment disclosure, and measurement values, advanced navigation protection, unsupported-selector handling, and independent data stores.

These checks verify native configuration, not remote rule availability, relay service access, fingerprint uniqueness, or ad-report delivery. The existing settings toolbar test visits Privacy, and transaction tests include privacy flags in rollback coverage.
