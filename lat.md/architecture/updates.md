# Application updates

Signed application updates, launch scheduling, and updater presentation.

See [[lat.md/tests/updates-tests|Test coverage]].

## Application updates

[[Sources/Browse/AppUpdater.swift#AppUpdater]] coordinates Sparkle updates for packaged production builds. Debug and unpackaged runs never start update checks or install production builds.

Sparkle checks the signed HTTPS feed hourly. At launch, [[Sources/Browse/AppUpdater.swift#AppUpdater#needsLaunchCheck]] requests a background check when the last check was at least ten minutes ago, is missing, or is future-dated. The check runs immediately after Sparkle starts, respects disabled automatic checks, and leaves subsequent scheduling and timestamp persistence to Sparkle. Scheduled discoveries show an Update to VERSION button in the sidebar without interrupting browsing; Bend’s menu also offers Check for Updates. Selecting an update opens Sparkle’s native download/install interface. Its separate signed helper verifies the archive before extraction, replaces the running application at its existing installation path, handles authorization when needed, and relaunches. Automatic download and unattended installation are disabled. Normal termination saves the regular session and cleans up private windows through the existing app delegate.

[[Sources/Browse/AppUpdater.swift#AppUpdateButton]] observes one shared coordinator across windows. Its warm amber-yellow interactive Liquid Glass capsule sits below the media player when both appear, using the tab rows’ height, horizontal insets, icon slot, and title alignment in docked and floating sidebars on either side. Sparkle’s gentle-reminder callbacks clear the button when the user opens the update or the update session ends. [[lat.md/tests/updates-tests#Application updater isolation]] covers production eligibility, debug isolation, and callback registration. [[lat.md/tests/updates-tests#Application update launch scheduling]] covers launch timing and the packaged hourly interval. [[releases#Signed update feed]] describes release signatures and hosting.

## Update interface preview

[[Sources/Browse/AppUpdatePreview.swift#AppUpdatePreview]] drives Sparkle’s real update windows with a local fixture and simulated progress, without creating an updater or installer. It is excluded from production compilation.

Building with `./scripts/build-app.sh --preview-updates` enables a debug-only bundle marker. [[Sources/Browse/AppUpdater.swift#AppUpdater#start]] then displays the normal sidebar button for an illustrative version. Clicking it shows release notes, simulated downloading and extraction, and Install and Relaunch; the last action shows a completion explanation while Bend stays open. Cancellation stops progress, and the sidebar button can replay the preview. The fixture decodes the pinned Sparkle version’s archived user-state format because its public interface has no state initializer. [[lat.md/tests/updates-tests#Application update preview]] exercises the native screens and debug-only routing. A normal debug rebuild removes the marker; production packaging rejects the preview option.
