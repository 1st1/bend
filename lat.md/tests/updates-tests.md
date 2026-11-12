---
lat:
  require-code-mention: true
---
# Application updates tests

Tests verify signed application updates, launch scheduling, and updater presentation.

See [[lat.md/architecture/updates|Architecture and behavior]].

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
