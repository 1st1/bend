# Releases

Bend keeps its app version in [[VERSION]] and user-facing release notes in [[CHANGELOG.md]]. [[.changie.yaml]] configures Changie to collect independent fragments and group them by change type.

## Change entries

Each user-facing feature, fix, or behavior change adds a fragment under [[.changes/unreleased]]. Internal-only changes do not need public release notes.

Run `./scripts/changie.sh new` and choose Added, Changed, Fixed, Removed, or Security. Describe the effect on the user in a short sentence. Commit the generated YAML with the implementation. [[scripts/changie.sh]] downloads Changie 1.26.0 into the ignored build cache and verifies the pinned platform-specific SHA-256 before execution; no global installation is required.

[[.github/workflows/changelog.yml]] validates metadata on pull requests and pushes to main. PRs changing Sources, Assets, or Package.swift require a newly added fragment unless they prepare a release or carry the `no-changelog` label. That label waives only the fragment requirement, not version or changelog validation. The metadata job has read-only repository permissions and no signing secrets. The production job is described under [[releases#GitHub build workflow]].

## Version and build identity

[[scripts/version.sh]] reads the checked-in [[VERSION]] for both debug and production app versions. [[scripts/build-app.sh]] writes it into the app plist, and [[scripts/build-prod.sh]] derives the DMG filename from that plist.

Versions have exactly three numeric components with no leading zeroes, prefix, or prerelease suffix. Feature releases increment the minor version while Bend is pre-1.0; fixes increment the patch version. The initial 0.1.0 entry normalizes the earlier 0.1 prototype baseline without inventing historical release notes.

`BEND_BUILD_NUMBER` supplies a positive integer for the separate bundle build number and defaults to 1 for local builds. The GitHub workflow uses its run number times 1000 plus the attempt number for candidate build identity; fresh runs and retries within a run increase it. Rerunning an older workflow retains its older run-number range. Local builds default to 1. Invalid version or build-number values fail before compilation or bundle replacement. Both profiles require macOS 26 or later; architecture remains the build host architecture.

## Prepare a release

Edit [[VERSION]] to the intended new version, then run `python3 scripts/release.py prepare`. The command batches pending fragments into that version’s release notes and regenerates [[CHANGELOG.md]].

For example, change VERSION from `0.1.0` to `0.2.0`, then run the preparation command. Review and commit VERSION, CHANGELOG.md, and all changes under `.changes`, including consumed fragment deletions, in the release PR. The command refuses to reuse or decrease an existing version and requires at least one fragment. Adding VERSION to a repository establishes a baseline; only a subsequent increase requests a production candidate. It does not commit, tag, sign, or publish anything.

Run `python3 scripts/release.py check` locally, or add `--base-ref COMMIT` to validate against a PR base. [[scripts/release.py#check]] requires VERSION to match the latest notes, checks the generated changelog against Changie output, validates pending fragments, rejects historical note rewrites, and reports whether VERSION changed. A missing unreleased directory represents no pending fragments, as in a clean checkout after batching the last entry; validation does not recreate it. Release PRs must consume all pending fragments. Changing VERSION without preparing matching notes fails validation. [[tests#Release metadata and changelog]] covers preparation and rejection cases.

## GitHub build workflow

[[.github/workflows/changelog.yml]] validates metadata, builds production, and runs Swift tests on pull requests and main pushes. A version increase requests signing for same-repository PRs and pushes to main.

The native job runs on GitHub’s ARM64 macOS 26 image with Xcode 26.6 selected explicitly. It runs packaging-script tests, compiles Release with the production profile, and runs the complete Swift suite through [[scripts/test.sh]], with serial execution and a fresh process for each native test. The same runner is used locally to preserve the installed SDK in the linked test binary and avoid older AppKit compatibility behavior. The test step has a thirty-minute timeout and restricts the Swift cooperative pool to one worker to catch blocking async work. SDK linking retains the actual installed SDK and the macOS 26 deployment target. Run steps explicitly select Bash so GitHub enables pipefail; tee preserves logs without hiding compiler or test failures. Native logs and available test-process crash reports are uploaded on success or failure. Individual process failures do not stop later test groups, so the final report captures the whole discovered inventory. The aggregate CI check requires metadata and native success for every run, successful signing for version bumps, and successful publication for version-bump pushes to main. Fork release PRs cannot obtain signing secrets or satisfy the production requirement. No path filter suppresses checks; every update to a release PR rebuilds its candidate. Obsolete PR runs are cancelled. Main pushes use separate commit-based concurrency groups so a later push cannot cancel a release in progress.

The production job uses the release-signing GitHub environment. [[scripts/ci-signing.py#setup]] imports an exported Developer ID identity into a private temporary keychain, installs API-key notarization credentials, and removes raw credential files after import. [[scripts/ci-signing.py#cleanup]] restores the original keychain search list and deletes the temporary credentials, including after failure. [[scripts/build-prod.sh]] accepts BEND_NOTARY_KEYCHAIN to use that exact keychain. [[tests#CI signing credential lifecycle]] covers cleanup without accessing real credentials.

Successful candidates upload the verified DMG as a single unarchived Actions artifact, preserving its .dmg filename for direct download. The workflow summary links to it. A separate build-details ZIP contains the SHA-256 checksum, release notes, and version/build/commit/SDK provenance. Failed notarization retains diagnostic artifacts. Main-branch version bumps then run [[releases#Automatic release publication]]. The release-signing environment contains the public Developer ID identity variable and all five certificate and notarization secrets. Credential validity is checked when the signing job runs. Setup instructions are in [[docs/github-build-setup.md]].

## Automatic release publication

A version bump merged into main triggers a fresh signed build of that merge commit, then [[scripts/publish-release.py#publish]] creates its version tag and GitHub Release with direct-download assets.

Metadata compares VERSION with the push event's previous commit; ordinary pushes and initial version-file creation do not publish. PR fragment enforcement remains in PR checks, while main pushes still validate versions, generated notes, and historical immutability. Manual workflow dispatch validates and tests without releasing. Publication requires successful metadata, native, and signing jobs and uses only their exact artifact IDs from the same run. Only the publishing job receives contents-write permission; it has no signing secrets. Publications for the same version are serialized without cancelling the running attempt.

[[scripts/publish-release.py#validated_assets]] checks the main-push event, checked-in version, source commit and run provenance, DMG checksum, and exact release notes before remote mutations. [[scripts/publish-release.py#publish]] creates a lightweight vMAJOR.MINOR.PATCH tag at the built commit, or verifies an existing lightweight or annotated tag resolves there. Conflicting tags are never moved. It creates or resumes a draft, uploads the DMG, SHA256SUMS, RELEASE_NOTES.md, and build.json, and checks uploaded sizes and SHA-256 digests before publishing. The release body uses the checked-in version notes; GitHub's semantic-version-aware latest selection is used.

Failed uploads leave a draft for a workflow retry. Retrying a completed release verifies the tag and required uploaded assets, then returns without replacing published binaries. Rerun failed jobs on the original main-push run to recover; no extra version bump is needed. [[tests#GitHub release publication]] covers validation and failure recovery without creating real tags or releases.
