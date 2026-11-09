# GitHub production build setup

The changelog/version validation workflow is implemented. The steps below describe the remaining production workflow and repository setup; signed GitHub builds and publication are not enabled yet.

## Release contract

`VERSION` is the source of truth. A pull request increasing it, with matching prepared changelog notes, should build a production candidate. Every subsequent code update to that release PR should rebuild the candidate, even when the update does not itself edit VERSION. Ordinary PRs run checks without signing a release.

Compare the checked-out PR with its base using `python3 scripts/release.py check --base-ref "$BASE_SHA"`; its `version_changed` output is suitable for a job condition. Do not use a workflow-level `paths: [VERSION]` filter: use the semantic comparison and keep required status checks present on every PR. Checkout the same commit for validation, tests, and packaging. Include the commit SHA and build number in uploaded artifact names.

Candidates belong in Actions artifacts. Merging and publishing a GitHub Release should be a separate step, so an unmerged PR never becomes the public latest release. A later publishing workflow should build the merged commit, tag that exact commit, attach the DMG/checksum/release notes to a draft release, then publish only after verification. Never silently replace an already published version.

## 1. Select a working macOS toolchain

Use an Apple Silicon macOS 26 runner and pin a tested Xcode installation instead of relying on `macos-latest`. GitHub's [macOS 26 ARM64 image inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md) currently lists Xcode 26.x SDKs.

The media menu uses a guarded dynamic call for the public `NSMenuItem.preferredImageVisibility` preference, so the macOS 27 SDK is not required. Use a macOS 26.5 SDK and keep the deployment target at 26.0. Verify the app and its tests with the selected GitHub toolchain before adding signing credentials; local SDK validation does not establish hosted-runner UI-test behavior.

## 2. Create the signing environment

In the repository, open **Settings → Environments** and create `release-signing`. Restrict signed builds to trusted same-repository release PRs; fork PRs run the metadata and unsigned checks only. Use `pull_request`, not `pull_request_target` with PR code. Configure environment review if contributors can push branches that should not automatically receive signing credentials.

Export the **Developer ID Application** certificate together with its private key from Keychain Access as a password-protected `.p12`. Add these environment secrets:

| Secret | Value |
| --- | --- |
| `BEND_CERTIFICATE_P12_BASE64` | Base64 contents of that `.p12` |
| `BEND_CERTIFICATE_PASSWORD` | Export password |
| `BEND_NOTARY_KEY_P8` | App Store Connect team API private key contents |
| `BEND_NOTARY_KEY_ID` | API key ID |
| `BEND_NOTARY_ISSUER_ID` | Team API issuer ID |

Add environment variable `BEND_SIGNING_IDENTITY` with the full Developer ID Application certificate name. The API key must be authorized for notarization. The existing local `bend-notary` profile and private key do not automatically exist on a hosted runner.

## 3. Add the production candidate job

Add a job to the PR workflow, dependent on successful metadata validation, with `environment: release-signing` and a condition requiring a VERSION increase and a same-repository PR. Configure a timeout covering both notarization submissions. Pin third-party actions to reviewed commits.

The job must:

1. Check out the validated commit and select the tested Xcode toolchain. Confirm `uname -m` is `arm64` and print Swift/SDK versions.
2. Run the Swift tests, `bash scripts/test-build-app.sh`, and `bash scripts/test-build-prod.sh`. Test native UI behavior on the runner before making those checks mandatory.
3. Decode the certificate into `$RUNNER_TEMP`, create/unlock a temporary keychain, import the `.p12`, and set its key partition list to `apple-tool:,apple:` so codesign works without a prompt. Preserve and restore the original keychain search list.
4. Write the API private key into `$RUNNER_TEMP` with restrictive permissions and run `xcrun notarytool store-credentials bend-notary --key PATH --key-id ID --issuer ISSUER --keychain TEMP_KEYCHAIN`. Include this keychain in the user's keychain search list so the existing build script can find the profile.
5. Allocate a unique increasing numeric `BEND_BUILD_NUMBER` for every candidate, including retries. A single workflow can derive it from `github.run_number` and `github.run_attempt` with a bounded retry field; do not reset the counter when recreating the workflow. Export `BEND_SIGNING_IDENTITY` and `BEND_NOTARY_PROFILE=bend-notary`.
6. Run `./scripts/build-prod.sh`. It builds production from source, signs/notarizes/staples the app, creates the DMG with dmgbuild, signs/notarizes/staples the DMG, verifies Gatekeeper, and then publishes the local artifact. Python 3 and network access to PyPI are needed for its first dmgbuild setup; dependencies are pinned in `scripts/dmgbuild-requirements.txt`.
7. Generate a SHA-256 file and upload only the final `dist/Bend-VERSION-arm64.dmg`, checksum, `.changes/vVERSION.md`, and build provenance. Upload `dist/notary-*` as diagnostic artifacts on failure. Do not upload the whole work directory or keychain.
8. In an `always()` cleanup step, restore the keychain search list, delete the temporary keychain, and remove the `.p12` and `.p8` files.

GitHub documents the [temporary-keychain signing approach](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications). Only the eventual publication job needs repository `contents: write`; candidate building and artifact uploading do not require a personal access token.

## 4. Turn on required checks and run the first candidate

Push the workflow and enable Actions. Add **Changelog and version** as a required check in the main-branch ruleset. Create the `no-changelog` label for internal-only PRs. Once the native job has passed on the selected runner, require its aggregate status too; non-release PRs must satisfy that status without needing a signing job.

On a release branch, edit VERSION to `0.2.0` and run:

```sh
python3 scripts/release.py prepare
python3 scripts/release.py check
git add VERSION CHANGELOG.md .changes
```

Commit and open a PR. Confirm the candidate job runs, download its artifact, and smoke-test it on macOS 26 and the current macOS release. A second commit to that PR should produce a new candidate with the same app version and a higher build number. A PR that only adds a normal changelog fragment must not start production signing.
