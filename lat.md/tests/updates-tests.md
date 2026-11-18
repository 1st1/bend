---
lat:
  require-code-mention: true
---
# Application updates tests

Tests verify signed application updates, launch scheduling, and updater presentation.

See [[lat.md/architecture/updates|Architecture and behavior]].

## Application updater isolation

[[Tests/BrowseTests/AppUpdaterTests.swift#applicationUpdaterIsolation]] verifies only packaged production apps are eligible for updates, debug checks are no-ops, Sparkle’s optional reminder and release-notes callbacks are registered with their exact selectors, and Markdown release notes render inline code and safe links while ignoring HTML items.

## Application update feed

[[scripts/test-update-feed.py#UpdateFeedTests]] verifies exact archive/build metadata, XML-escaped Markdown release notes with `sparkle:format="markdown"`, rejection of invalid metadata, and signatures using a public RFC test key on macOS. Tampered archives/feeds and mismatched signing keys are rejected.

The manual verification helper is exercised with a mocked Keychain export and real signing tools, checking one export per run, progress and success output, restrictive permissions, and cleanup after success or key mismatch.

## Application update launch scheduling

[[Tests/BrowseTests/AppUpdaterTests.swift#applicationUpdateLaunchScheduling]] verifies that launch checks respect the ten-minute boundary and recover from missing or future-dated check times.

Recent checks suppress the additional launch request; older checks permit it. [[scripts/test-build-app.sh]] checks that the packaged production app schedules hourly background checks.

## Application update preview

[[Tests/BrowseTests/AppUpdaterTests.swift#applicationUpdatePreview]] exercises debug-only preview eligibility, the pinned Sparkle Markdown fixture, real update windows with rendered native release notes, download cancellation, replay, and the simulated Install and Relaunch action.

The preview uses no updater or installation helper. The test supplies an isolated bundle and intercepts the completion explanation; the running test process survives the final button. Packaging coverage in [[scripts/test-build-app.sh]] verifies opt-in metadata, its removal by normal builds, and rejection of preview production builds.

## Changelog content and routing

[[Tests/BrowseTests/ChangelogTests.swift#changelogContentAndRouting]] verifies release parsing, Markdown/link rendering, bundled loading, native address/title routing, tab reuse, session persistence, and exclusion from web history.

[[Tests/BrowseTests/ChangelogTests.swift#changelogPageLayout]] renders the real changelog at wide and narrow widths and optionally captures snapshots. Packaging tests verify the embedded file matches the complete source changelog.

Release dates are checked for valid calendar days, missing or malformed metadata, bundle loading, and rendering at both pane widths.

## Post-update release notes

[[Tests/BrowseTests/ChangelogTests.swift#postUpdateReleaseNotes]] verifies first-launch baselining, version/build upgrades, quiet restarts and rollbacks, debug/malformed metadata exclusion, regular-window routing, and reuse of an existing changelog tab.
