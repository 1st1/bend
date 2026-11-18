# Application updates

Signed application updates, launch scheduling, and updater presentation.

See [[lat.md/tests/updates-tests|Test coverage]].

## Application updates

[[Sources/Browse/AppUpdater.swift#AppUpdater]] coordinates Sparkle updates for packaged production builds. Debug and unpackaged runs never start update checks or install production builds.

Sparkle checks the signed HTTPS feed hourly. At launch, [[Sources/Browse/AppUpdater.swift#AppUpdater#needsLaunchCheck]] requests a background check when the last check was at least ten minutes ago, is missing, or is future-dated. The check runs immediately after Sparkle starts, respects disabled automatic checks, and leaves subsequent scheduling and timestamp persistence to Sparkle. Scheduled discoveries show an Update to VERSION button in the sidebar without interrupting browsing; Bend’s menu also offers Check for Updates. Selecting an update opens Sparkle’s native download/install interface, which formats `sparkle:format="markdown"` release notes natively via [[Sources/Browse/AppUpdater.swift#AppUpdater#releaseNotesText]] and [[Sources/Browse/ChatMarkdown.swift#ChatMarkdownDocument#render]] using adaptive Light/Dark inline-code backgrounds and `https`/`http` links. Its separate signed helper verifies the archive before extraction, replaces the running application at its existing installation path, handles authorization when needed, and relaunches. Automatic download and unattended installation are disabled. Normal termination saves the regular session and cleans up private windows through the existing app delegate.

[[Sources/Browse/AppUpdater.swift#AppUpdateButton]] observes one shared coordinator across windows. Its warm amber-yellow interactive Liquid Glass capsule sits below the media player when both appear, using the tab rows’ height, horizontal insets, icon slot, and title alignment in docked and floating sidebars on either side. Sparkle’s gentle-reminder callbacks clear the button when the user opens the update or the update session ends. [[lat.md/tests/updates-tests#Application updater isolation]] covers production eligibility, debug isolation, callback registration, and Markdown release-notes rendering. [[lat.md/tests/updates-tests#Application update launch scheduling]] covers launch timing and the packaged hourly interval. [[releases#Signed update feed]] describes release signatures and hosting.

## Update interface preview

[[Sources/Browse/AppUpdatePreview.swift#AppUpdatePreview]] drives Sparkle’s real update windows with a local fixture and simulated progress, without creating an updater or installer. It is excluded from production compilation.

Building with `./scripts/build-app.sh --preview-updates` enables a debug-only bundle marker. [[Sources/Browse/AppUpdater.swift#AppUpdater#start]] then displays the normal sidebar button for an illustrative version. Clicking it shows Sparkle’s release-notes dialog rendered through [[Sources/Browse/AppUpdater.swift#AppUpdater#releaseNotesText]] with a Markdown fixture (headings, bullets, inline code, and a link), simulated downloading and extraction, and Install and Relaunch; the last action shows a completion explanation while Bend stays open. Cancellation stops progress, and the sidebar button can replay the preview. The fixture decodes the pinned Sparkle version’s archived user-state format because its public interface has no state initializer. [[lat.md/tests/updates-tests#Application update preview]] exercises the native screens, rendered release notes, and debug-only routing. A normal debug rebuild removes the marker; production packaging rejects the preview option.

## What's New page

[[Sources/Browse/Changelog.swift#Changelog]] parses the bundled release history for the native `bend://log` page, with versions in the order published in [[CHANGELOG.md]].

[[scripts/build-app.sh]] copies the complete changelog into both app profiles before signing, so release notes are available offline and match the installed build. Dates come from bundled [[.changes/release-dates.json]], seeded from GitHub publication dates and recorded in UTC when future releases are prepared. Calendar dates display without timezone shifts; unknown dates (including the prototype baseline) are omitted. Markdown release headings define version sections; introductory repository-maintenance prose is omitted. [[Sources/Browse/ChangelogView.swift#ChangelogView]] renders selectable Markdown cards, release dates, an Installed badge, and a readable empty state when notes are unavailable. Web links open in new Bend tabs; other link schemes are ignored, and embedded HTML/images never execute or fetch content.

[[Sources/BrowseCore/Session.swift#AddressResolver]] accepts the native address and supplies its friendly title. [[Sources/Browse/BrowserStore.swift#BrowserStore#showChangelog]] selects an existing log pane across workspaces or creates a new tab without replacing browsing pages. The app menu and command popup expose What's New. The page participates in normal session restoration and is excluded from website history. AI can read its bundled notes and installed Bend version through the tab-scoped read tool; other native pages remain inaccessible.

## Post-update release notes

[[Sources/Browse/Changelog.swift#WhatsNewTracker]] detects a newer running production bundle and consumes that upgrade once, independently of whether Sparkle or manual replacement installed it.

[[Sources/Browse/BrowseApp.swift#AppDelegate#showReleaseNotesIfUpdated]] opens the changelog after restoring browser windows, choosing a regular window even if a private one is active. First launch establishes a baseline without opening notes. Subsequent higher semantic versions or higher builds of the same version open notes; ordinary restarts, malformed metadata, debug/unpackaged runs, and downgrades do not. A high-water mark prevents rollback/reinstallation from replaying already-seen notes. Merely finding, downloading, or cancelling an update cannot trigger the page because the installed identity has not changed.

The baseline begins with the first production launch that includes this tracker; no prior installed version is inferred for older builds that did not record one. [[Sources/Browse/Changelog.swift#InstalledRelease]] compares numeric version/build strings without integer conversion, including versions whose build numbering restarts.
