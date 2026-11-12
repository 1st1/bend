---
lat:
  require-code-mention: true
---
# Extension compatibility tests

Tests verify native messaging and browser API adapters for supported extensions.

See [[lat.md/architecture/extensions/compatibility|Architecture and behavior]].

## Safari uBlock Lite compatibility

[[Tests/BrowseTests/UBlockLiteTests.swift#safariUBlockLiteSmoke]] probes the unmodified Safari uBlock Origin Lite package in an isolated Bend host with temporary extension and website storage.

Set `BROWSE_TEST_UBLOCK_SAFARI_PACKAGE` to the Safari extension bundle or official Safari ZIP. The package must report Safari from its own browser-detection module in both its live background page and popup, resolve real resource URLs on that origin, and select the Safari-specific disabled strict-blocking default. Diagnostic-only background-view access reads the loaded modules and logs their values. The probe verifies its identity, starts its background, tests an EasyList-matched script against a local HTTP fixture, and clicks the popup’s site filtering controls to turn blocking off and back on, then checks extension disable/re-enable behavior. A baseline verifies the script runs without the extension. The probe never changes the user's installed extensions.

## Extension compatibility permissions and notifications

[ExtensionCompatibilityTests.swift](../../../Tests/BrowseTests/ExtensionCompatibilityTests.swift) verifies WebKit extension messaging survives the adapters, notification IDs are isolated, callbacks report errors, permission revocation is enforced, and websites cannot call the bridge.

An injected notification backend exercises create, enumeration, click routing, clear, and disable cleanup without displaying system notifications or changing system authorization. The fixture uses its own ephemeral website data store.

## Extension created navigation events

[ExtensionCompatibilityTests.swift](../../../Tests/BrowseTests/ExtensionCompatibilityTests.swift) verifies a main-frame link opening emits a navigation-target event with the real WebKit tab ID while native tab events still arrive.

Unrelated tab creation and subframe openings do not produce a fabricated main-frame event. URL filtering is exercised with the fixture destination.

## Embedded extension pages and tab transitions

[ExtensionCompatibilityTests.swift](../../../Tests/BrowseTests/ExtensionCompatibilityTests.swift) verifies embedded extension messaging and website-to-extension tab updates with local, account-free fixtures.

A declared web-accessible iframe communicates with its background, while a private resource cannot run in the website. Website-initiated top-level extension navigation is rejected. An extension's tab update loads its own document with the same tab identity; a saved pane restores after its extension loads. Disabling tears down that document, and following a web URL returns to an ordinary view without privileged extension APIs.

## Firefox onboarding smoke test

[ExtensionCompatibilityTests.swift](../../../Tests/BrowseTests/ExtensionCompatibilityTests.swift) optionally loads a real Firefox 1Password package through Bend's production extension manager in an isolated, windowless profile.

Set `BROWSE_TEST_FIREFOX_PACKAGE` to a local official XPI to run this network-dependent test. It verifies action-driven onboarding, declines three optional choices in disposable data, and follows Sign in to the official email form in the same logical tab. An extension-authorized return reuses the original view and skips the already-answered choices. It enters no credentials and does not establish authenticated sign-in, desktop integration, autofill, or account persistence. Without the environment variable, it returns without loading a real package.

## Extension browser information and menu settings

[[Tests/BrowseTests/ExtensionCompatibilityTests.swift#extensionBrowserSettings]] verifies browser identity, permission approval and revocation, callback errors, and the fixed mouse-down menu setting through real WebKit extension pages.

Set and clear return false, no change events fire, invalid values and private scopes fail, unavailable optional-permission queries return false, and native storage continues working alongside the adapters.

## Foxy Gestures options smoke test

[[Tests/BrowseTests/ExtensionCompatibilityTests.swift#foxyGesturesOptionsSmoke]] optionally loads the real Foxy package from BEND_TEST_FOXY_PACKAGE into isolated storage to verify rendered settings and saved preferences.

The test configures a middle-button downward gesture and exercises native WebKit input against a local page, requiring the extension to open a new tab. No user installation or preferences are changed.

## Extension privacy settings and restored startup

[ExtensionCompatibilityTests.swift](../../../Tests/BrowseTests/ExtensionCompatibilityTests.swift) verifies privacy approval, persistent grants, disabled saver settings, callback errors, revocation, and startup calls gated on saved configuration across host recreations.

The fixture stores a configured flag before restarting its host, then uses the password-saving and autofill settings during background startup before answering messages. It uses no credentials or real vault. Unsupported enabling is rejected rather than claiming to implement a built-in saver.

## Extension document authentication round trip

[ExtensionCompatibilityTests.swift](../../../Tests/BrowseTests/ExtensionCompatibilityTests.swift) verifies that same-tab extension-to-website-to-extension navigation preserves session storage and tab identity without giving the website extension privileges.

A local website cannot read the extension's session storage, call the compatibility bridge, or authorize its own return to a privileged document. An explicit extension tab update returns to the retained view with the original setup marker; the flow creates no extra browser pane. Return readiness requires completed navigation and replacement of a document-only marker, since retained session storage is already readable in the old document. Navigation triggers use synchronous JavaScript evaluation so the test does not depend on an injected async function surviving a document transition. Asynchronous API probes retain their promise and result in the document and poll with a bounded timeout, preserving API errors without depending on a collectable injected completion handler.

## Dark Reader compatibility smoke test

[DarkReaderTests.swift](../../../Tests/BrowseTests/DarkReaderTests.swift) exercises the official Firefox Dark Reader package through Bend's production extension host with temporary storage and a local HTTP page.

Set `BROWSE_TEST_DARK_READER_PACKAGE` to the official 4.9.134 XPI. The test verifies the pinned SHA-256 and package identity, computed dark colors, popup global and per-site toggles, and disable/re-enable with page reloads. The popup runs windowlessly; this checks its DOM controls and messaging, not native popover placement. It does not touch the user's profile or establish compatibility across arbitrary websites. Without the environment variable, the package test is skipped.

## Native extension messaging

[ExtensionCompatibilityTests.swift](../../../Tests/BrowseTests/ExtensionCompatibilityTests.swift) exercises real WebKit native-message calls with an isolated Python echo helper, including restoration, revocation, disconnects, and invalid frames.

One-shot and persistent messages cross the delegate boundary and handle fragmented JSON replies. CI restricts Swift's cooperative pool to one worker to expose blocking pipe reads that would starve other async work. Recreated managers restore permission and reconnect; permission denial and context teardown empty the connection registry. Host crashes and oversized frames reject promises. Unit checks cover Unicode, concatenated frames, manifest allowlists, missing hosts, and traversal rejection. The opt-in Firefox onboarding smoke verifies the real 1Password package requests its registered helper, while an injected resolver prevents access to the user's desktop vault. Touch ID and authenticated desktop unlocking require a separate manual test.

## Safari mouse gestures

[[Tests/BrowseTests/ExtensionCompatibilityTests.swift#mouseGesturesSafariSmoke]] optionally imports the app specified by BEND_TEST_MOUSE_GESTURES_APP into isolated storage, verifies settings, and opens a tab with native right-button input.

An injected app lookup and store opener verify the App Store handoff, cancellation, launch failure, and resumption without duplicate imports. The installed package's default leftward gesture uses Safari's favorites URL, which must open Bend's start page. The test never changes the user's installed app or extension preferences.
