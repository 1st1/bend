---
lat:
  require-code-mention: true
---
# Build and signing tests

Tests verify development builds, distribution signing, and isolated application profiles.

See [[lat.md/architecture/build|Architecture and behavior]].

## Build bundle publication

[test-build-app.sh](../../scripts/test-build-app.sh) runs the packaging script with isolated compiler and signing stand-ins, verifying failure preservation and replacement without changing an open descriptor to the previous executable.

Signing and verification failures retain the previous bundle and executable inode. Successful publication installs a new inode and removes staging files. The test checks VERSION and BEND_BUILD_NUMBER propagation into both profiles, invalid metadata rejection without replacing an existing bundle, the macOS 26 minimum in both profiles and the linker arguments, Debug’s distinct name, identifier, compiler configuration, and profile marker, production’s explicit Release flag and retained identifier, publication without touching the other channel, the icon resource and plist entry, HTTP/HTTPS URL-handler and HTML/XHTML document-viewer declarations, and precedence of the new signing override over the legacy override. These checks do not exercise macOS signing or WebKit runtime behavior.

## Production installer publication

[test-build-prod.sh](../../scripts/test-build-prod.sh) exercises the production script with isolated native-tool stand-ins, checking notarization, ticket validation, packaging order, and failure-safe publication.

App or DMG rejection, headless packaging failure, invalid tickets, and disk-image verification failure retain the previous installer and detach temporary mounts. Successful publication requires the app ticket before packaging and the DMG ticket before final assessment. Failures retain their notarization logs; success removes only its own log folder while preserving earlier failure logs. The development app remains untouched by production compilation, packaging, and stapling; the production script must explicitly request its profile and output path. These tests do not substitute for Apple's real service or native disk-image layout verification.

## Build profile isolation

[[Tests/BrowseTests/AppProfileTests.swift#buildProfileIsolation]] verifies separate debug and production names, bundle IDs, support directories, preference domains, window-state keys, and WebKit store identities.

A unique temporary preference and cookie marker written in Debug must be absent from production, and both markers are removed after the test. Store wrappers remain retained throughout the async cookie checks. The debug extension manager must use the debug extension and website stores. Simulated packaged-host identities must select standard UserDefaults, covering the case missed by a test bundle with a different identifier. The signed executable’s `--print-build-profile` path also reads preferences before returning. [[lat.md/tests/build-tests#Build bundle publication]] and [[lat.md/tests/build-tests#Production installer publication]] verify the packaging boundary independently of runtime storage.

## Release metadata and changelog

[[scripts/test-release.py#ReleaseTests]] runs real Changie in disposable repositories to verify version-driven release preparation and PR checks without changing the working project.

The tests verify fragment consumption, validation when a clean checkout omits the empty fragment directory, malformed-fragment rejection, matching version notes and changelog generation, refusal to reuse or decrease versions, baseline initialization without a release trigger, invalid version rejection, required fragments for user-facing changes, the internal-only escape, stale changelog detection, immutable historical release notes, a merged version bump detected against the push boundary, a later unchanged-version push that does not release, and a revised untagged candidate that requests a fresh release without changing VERSION. Tagged candidates and older notes remain immutable; revisions must consume all pending fragments. Run `python3 scripts/test-release.py`; no signing credentials are required.

## CI signing credential lifecycle

[[scripts/test-ci-signing.py#SigningTests]] verifies temporary credential handling with mocked system commands, without touching a real keychain or contacting Apple.

Coverage includes restrictive file permissions, raw credential removal after import, original keychain search-list restoration, cleanup after notarization setup failure, removal even when keychain commands fail, and missing-secret rejection before system changes. Run `python3 scripts/test-ci-signing.py`.

## GitHub release publication

[[scripts/test-publish-release.py#PublicationTests]] exercises release publication with temporary build artifacts and a simulated GitHub service, without pushing tags or creating real releases.

Coverage includes exact-commit tags, complete asset upload before publication, draft recovery after partial upload failure, rejection of conflicting tags and mismatched checksums, notes, or provenance, upload digest verification, and reruns that leave published binaries untouched. [[scripts/test-publish-release.py#APIErrorTests]] distinguishes a missing resource from permission or network errors so API failures cannot silently trigger creation. Run `python3 scripts/test-publish-release.py`.

## Native test runner coverage

[[scripts/test-test-runner.py#TestRunnerTests]] verifies full inventory execution, skip accounting, rejection of unmatched filters and ambiguous names, failed-process propagation, timeout termination, and continued execution after failures, crashes, timeouts, or missing results.
