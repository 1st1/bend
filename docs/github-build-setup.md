# GitHub production builds

Bend CI is defined in `.github/workflows/changelog.yml`. Every PR and main push validates release metadata, compiles production, and runs the Swift tests on an Apple Silicon macOS 26 runner with Xcode 26.6. A same-repository PR increasing VERSION also builds a signed, notarized DMG candidate. Merging the version bump into main triggers a fresh signed build, then automatically creates the version tag and publishes a GitHub Release. The initial addition of VERSION establishes a baseline without requesting a release.

Every update to a release PR rebuilds its candidate. The workflow compares VERSION with the PR base rather than using a paths filter, and all jobs check out the same event commit. Main pushes compare VERSION with the previous main commit. The aggregate **CI** check requires signing for version bumps and release publication for version-bump pushes to main. Actions are pinned to reviewed commit SHAs.

The notarized DMG is uploaded as an unarchived Actions artifact for direct download. Checksums, release notes, and build provenance are uploaded separately as a build-details ZIP. PR builds remain candidates; main-branch version bumps publish releases. The signing job uses temporary credentials, cleans them up on success or failure, and runs only for trusted same-repository release PRs and version-bump pushes to main. Fork PRs never receive signing secrets.

## One-time credential setup

The repository's `release-signing` environment, `BEND_SIGNING_IDENTITY` variable, `no-changelog` label, and all five signing and notarization secrets are configured. The signing job validates the credentials when it runs. The instructions below describe how to provision or replace them.

### Export the signing identity

Open **Keychain Access → My Certificates**. Find **Developer ID Application: Yury Selivanov (QA7X6JBN4H)**, expand it, and confirm its private key is present. Export the identity to a password-protected `.p12` file. A `.cer` file alone is insufficient because CI needs the private key to sign.

Save the file outside the repository. Upload it directly to the environment secret, replacing the example path:

```sh
base64 -i "/path/to/Bend.p12" | gh secret set BEND_CERTIFICATE_P12_BASE64 --repo 1st1/bend --env release-signing
gh secret set BEND_CERTIFICATE_PASSWORD --repo 1st1/bend --env release-signing
```

The second command prompts for the export password. Do not put that password in the command line or commit either credential file.

### Create the notarization API key

In **App Store Connect → Users and Access → Integrations → App Store Connect API → Team Keys**, create a key named **Bend CI** with **Developer** access. Use a team API key because the workflow supplies an Issuer ID. If API access has not been enabled, the Account Holder must request it first. Download the `.p8` private key and record its Key ID and Issuer ID. Apple permits only one private-key download. See [Apple's API key instructions](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api).

Upload the key and enter the identifiers at the prompts:

```sh
gh secret set BEND_NOTARY_KEY_P8 --repo 1st1/bend --env release-signing < "/path/to/AuthKey_KEYID.p8"
gh secret set BEND_NOTARY_KEY_ID --repo 1st1/bend --env release-signing
gh secret set BEND_NOTARY_ISSUER_ID --repo 1st1/bend --env release-signing
```

These credentials authorize notarization; distributing Bend as a DMG does not require listing it on the App Store. GitHub's [signing guide](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications) describes the temporary-keychain approach used by `scripts/ci-signing.py`.

### Verify configuration

List secret names without revealing values:

```sh
gh secret list --repo 1st1/bend --env release-signing
```

The list must contain all five names: BEND_CERTIFICATE_P12_BASE64, BEND_CERTIFICATE_PASSWORD, BEND_NOTARY_KEY_P8, BEND_NOTARY_KEY_ID, and BEND_NOTARY_ISSUER_ID. The environment variable BEND_SIGNING_IDENTITY is already configured with the full Developer ID certificate name.

## First production candidate

On a release branch, edit VERSION to `0.2.0` and run:

```sh
python3 scripts/release.py prepare
python3 scripts/release.py check
git add VERSION CHANGELOG.md .changes
```

Commit and open a PR. Successful metadata and native jobs unlock the production job, which signs, notarizes, and staples the app and DMG. Use the DMG download link in the workflow summary, or download the **Bend-VERSION-arm64.dmg** artifact directly. No ZIP extraction is needed. The separate **Bend-VERSION-build-details-RUN-ATTEMPT** artifact contains SHA256SUMS, RELEASE_NOTES.md, and build.json. Signing failures retain notarization diagnostics when available.

Each candidate uses `run_number * 1000 + run_attempt` as BEND_BUILD_NUMBER, with attempts bounded below 1000. Fresh runs and retries within a run increase it; rerunning an older workflow retains the older number range. The app version remains the value in VERSION.

Smoke-test a signed candidate on macOS 26 and the current release before merging. **CI** can be made a required check in the main-branch ruleset.

## Automatic publication after merge

Merge the version-bump PR into main. Once metadata, native tests, and the fresh signed production build pass, CI creates `vVERSION` at that exact main commit and publishes **Bend VERSION** with these directly downloadable assets:

- `Bend-VERSION-arm64.dmg`
- `SHA256SUMS`
- `RELEASE_NOTES.md`
- `build.json`

The release description comes from `.changes/vVERSION.md`. The `.dmg` asset is the installer itself, without a ZIP wrapper. Release visibility follows the repository's visibility; a private repository still requires access. GitHub's generated source archives may also appear alongside these assets.

The publisher uses the workflow's built-in `GITHUB_TOKEN` with `contents: write`, so no additional secret is required. Repository or organization rules must permit that token to create version tags and releases. Only the publish job has repository-write access; signing credentials stay in the signing job.

Failures before publishing leave a draft if one has already been created. Rerun failed jobs on the original main-push run to finish it. Existing tags must resolve to the built commit; the publisher refuses to move conflicting tags. Completed releases are not overwritten on rerun. Main releases are not cancelled by later pushes. Ordinary main pushes and manual workflow dispatch do not publish a release.
