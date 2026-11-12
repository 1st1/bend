# Independent extensions on WebKit

Bend can own extension installation, permissions, updates, and storage while retaining WebKit. Package management and runtime API compatibility are separate responsibilities. This document records research and proposed next steps, not a claim that 1Password works.

## Gesturefy and right-button gesture investigation

Gesturefy **3.2.19** was reproduced in disposable extension storage on macOS 27.2 (26B123). The installed package and user preferences were not changed. This investigation did not produce a working Gesturefy implementation.

Its content-script `ConfigManager` fetches `resources/json/defaults.json` with `mode: 'same-origin'`. In WebKit this rejects with `TypeError: Load failed`, preventing configuration initialization. Fetching the same resource from an extension page succeeds with HTTP-style status 200 and `application/json`; `.mjs` modules also have the expected JavaScript MIME type. In a disposable package copy, adding the JSON to `web_accessible_resources` made an ordinary content-script fetch succeed, but initialization still failed until its same-origin fetch mode was changed to CORS. Those package changes were experimental and are not applied by Bend's importer.

Gesturefy also requests Firefox's `browserSettings.contextMenuShowEvent` mouse-up behavior. Bend currently reports this setting as not controllable. Two native-menu experiments distinguished possible host workarounds:

- Holding WebKit's asynchronous proposed-menu completion blocks subsequent pointer movement and release. The probe received only trusted pointer-down and context-menu events, so delaying that completion is insufficient.
- Completing immediately with an empty menu allows trusted pointer-down, movement, and release events to reach the page. This is a potential basis for a host-side gesture mode, but menu suppression alone is not a complete fix: plain clicks must retain native menus and their actions, cancelled gestures and focus changes need cleanup, and DOM context-menu timing remains mouse-down.

The resource-adapted package plus immediate menu suppression still did not execute the probe's downward gesture mapped to New Tab. Further gesture recognition/command investigation is required; native event delivery alone does not establish compatibility. Temporary failing probes were removed from the test suite, and no input workaround was shipped.

Upstream [Gesturefy source](https://github.com/Robbendebiene/Gesturefy) documents its browser-settings dependency. WebKit's [menu proxy](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/WebContextMenuProxy.cpp) clears the waiting-for-menu state after the menu presentation call returns; the [macOS implementation](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/mac/WebContextMenuProxyMac.mm) owns native menu targets and presentation. A production workaround must preserve that lifecycle rather than merely retain an `NSMenu` object.

## Other browsers

[Orion](https://help.kagi.com/orion/browser-extensions/macos-extensions.html) installs Chrome and Firefox extensions and maintains its own WebExtensions API compatibility implementation. Its documentation describes substantial API-by-API engineering and incomplete coverage. Its implementation is [not currently open source](https://orionbrowser.com/help), so it is a behavioral reference rather than a reusable implementation.

[Orion's 1Password integration](https://help.kagi.com/orion/browser-extensions/1password.html) involved collaboration with 1Password and requires desktop-app browser authorization. This demonstrates that WebKit is not inherently incompatible with 1Password; it does not establish compatibility for a different host. [1Password's additional-browser requirements](https://support.1password.com/additional-browsers/) describe Chrome/Firefox extension support and Apple code signing on macOS.

[GNOME Web's extension manager](https://github.com/GNOME/epiphany/blob/master/src/webextension/ephy-web-extension-manager.c) installs XPI packages or copied folders into its profile. It owns background and popup views and dispatches extension calls to browser API handlers, including notifications, tabs, and runtime. This is a concrete open-source example of an independent extension host over WebKitGTK. Its GLib/GTK APIs are not directly interchangeable with Cocoa WKWebView. The source is GPL-3.0-or-later; this research does not copy its implementation into Bend.

## Findings in the WebKit checkout

The inspected checkout is `/Users/yury/dev/WebKit`, revision `f91ce22de4`, dated 2026-11-03. No modifications were made to that checkout.

- `Source/WebKit/UIProcess/Extensions/WebExtension.cpp`, `processFileAndExtractZipArchive`: WebKit reads ZIP packages and strips CRX headers before extraction. An XPI is a ZIP package. Reading these formats does not establish publisher authenticity or full Chrome/Firefox API compatibility.
- `Source/WebKit/WebProcess/Extensions/Interfaces/WebExtensionAPINotifications.idl` and `Source/WebKit/WebProcess/Extensions/API/Cocoa/WebExtensionAPINotificationsCocoa.mm`: notification API implementation exists in this checkout.
- `Source/WTF/Scripts/Preferences/UnifiedWebPreferences.yaml`, `WebExtensionNotificationsEnabled`: notifications are disabled by default behind a testable feature flag. `WebExtensionAPINamespace.cpp` also requires the extension's notification permission.
- `Source/WebKit/UIProcess/Extensions/Cocoa/API/WebExtensionContextAPINotificationsCocoa.mm`: presenting notifications requires the private `_webExtensionController:presentNotification:forExtensionContext:completionHandler:` delegate. Merely enabling the flag would not provide a working notification service. Availability in this checkout does not guarantee availability in the installed system framework.
- `Source/WebKit/WebProcess/Extensions/Interfaces/WebExtensionAPIWebNavigation.idl`: the navigation-target-created event used by the Firefox 1Password package is absent.
- `Source/WebKit/UIProcess/Extensions/Cocoa/API/WebExtensionContextAPIRuntimeCocoa.mm`: the default native-message path resolves an installed NSExtension by bundle identifier. Copying Safari resources does not create an independent native companion. Public controller delegate callbacks allow the browser to supply a different native-messaging transport.

## Implemented ownership boundary

Bend uses the system WebKit framework with its own app profile; it does not yet bundle a custom engine. All new imports are copied into Bend's extension directory. Existing externally referenced imports migrate to owned copies while retaining context identities and approved access. Source application updates no longer silently replace installed resources.

Settings supports manual local-package installation, replacement, enablement, removal, and options pages. Updates preserve the extension origin and storage, validate replacement identity where available, and hold additional permissions for review. These are explicitly selected local imports, not authenticated browser-store installs or automatic updates. Declared manifest IDs and keys are identity hints, not publisher verification.

## Safari native-host entitlement experiment

The windowless [native probe](../Tools/ExtensionProbe/native-host.m) calls the same `NSExtension extensionWithIdentifier:error:` Foundation SPI used by WebKit's default native transport. It does not send messages, read vault data, change Safari preferences, or alter extension registration. The [wrapper](../scripts/probe-native-extension.sh) builds and signs a temporary app with `Browse Dev`, verifies its signature, and removes the temporary bundle on exit. Override the signing identity with `BROWSE_PROBE_SIGNING_IDENTITY` if needed.

Reproduce the two configurations:

```bash
bash scripts/probe-native-extension.sh
BROWSE_PROBE_HOST_ENTITLEMENT=1 bash scripts/probe-native-extension.sh
```

On macOS 27.0.1 (26A434), with installed 1Password for Safari 8.12.42 (manifest 8.12.42.36), the default probe launches, returns `resolved: false`, and exits 1. Foundation supplies no NSError. PlugInKit logs the actual rejection: `the host does not have the "com.apple.private.can-load-any-content-blocker" entitlement`. Safari's `NSExtensionSDK` registration for `com.apple.Safari.web-extension` names this host entitlement.

With that entitlement set to true, signing and static signature verification succeed, but the process is killed before reaching main (exit 137). `amfid` reports `AppleMobileFileIntegrityError Code=-413 "No matching profile found"`. Repeating the control without the entitlement launches normally and reproduces the PlugInKit rejection. Neither configuration establishes a native connection.

Adding the entitlement to Bend's ordinary build would therefore make this locally signed app fail to launch. [Apple's provisioning documentation](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles) explains that restricted entitlements require authorization in a provisioning profile. This experiment does not establish that Apple offers this private entitlement to third-party browser developers; a normal development certificate alone is not demonstrated to solve it. System security settings were not changed. This establishes a restriction in the default native transport, not the cause of every WASM or IndexedDB error, nor whether Safari 1Password can start without its native companion.

## Firefox 1Password runtime reproduction

The official [Mozilla listing](https://addons.mozilla.org/en-US/firefox/addon/1password-x-password-manager/) and its [add-on metadata](https://addons.mozilla.org/api/v5/addons/addon/1password-x-password-manager/) supplied version **8.12.41.1** during this investigation. The tested [XPI](https://addons.mozilla.org/firefox/downloads/file/5097307/1password_x_password_manager-8.12.41.1.xpi) matched Mozilla's SHA-256: `6b00acff73253865303af49e99329245a940348484cbd931ea39f9fa215134f5`.

The [pinned reproduction script](../scripts/probe-onepassword-firefox.sh) accepts that downloaded XPI, validates its hash, extracts into a disposable directory, and runs the [windowless runtime probe](../Tools/ExtensionProbe/runtime.swift):

```bash
bash scripts/probe-onepassword-firefox.sh /absolute/path/to/1password-8.12.41.1.xpi
bash scripts/probe-onepassword-firefox.sh /absolute/path/to/1password-8.12.41.1.xpi --diagnostic-startup
```

In the standalone probe without Bend's compatibility adapters, the unmodified package stops during startup with `chrome.notifications.onClicked` undefined. The installed WebKit does not expose the `WebExtensionNotificationsEnabled` feature listed in the source checkout. Merely setting that feature through the probe's optional feature lookup therefore cannot fix this system framework.

The diagnostic-startup mode deliberately changes only its disposable copy: it skips registration of the unsupported `webNavigation.onCreatedNavigationTarget` listener and supplies notifications event-registration placeholders. Actual notification operations throw errors. This is not an installable compatibility solution and is never injected by Bend's production host.

With those two diagnostic changes, observed behavior includes:

- The real 1Password WASM core initializes. A streaming MIME-type warning falls back to ordinary WASM instantiation successfully.
- Its IndexedDB database upgrades to version 22, autofill rules initialize, and the background reports finished initialization.
- Native desktop connection attempts fail; the background transitions to a disconnected state rather than preventing all startup.
- Invoking the extension action opens its own welcome page, including Firefox's icon and data-collection choices. The page communicates with the background to obtain settings and the disconnected native-app state. A toolbar popup is not configured for this fresh account-free state.
- A context-menu update still reports an error. Notifications, navigation-target events, native integration, account sign-in, unlock, fill, save, and persistence across restart are not validated by reaching this welcome page.

The harness must grant private-data access to its own ephemeral store: WebKit classifies nonpersistent stores as private browsing and otherwise filters extension events. Early action-delivery and welcome-page failures without this grant were harness defects, not established Firefox-package incompatibilities. The probe now uses the same isolated store for the controller, background, and test tab; production private-data permissions are unchanged.

This diagnostic result established that Firefox 1Password could reach onboarding in WebKit after bypassing two startup gaps. No real account or vault data was used, and the normal Bend profile was not modified.

## Implemented Firefox onboarding support

Bend's [compatibility adapters](../Sources/Browse/ExtensionCompatibility.swift) now supply notifications through a [macOS backend](../Sources/Browse/ExtensionNotifications.swift), and main-frame navigation-target events derived from actual link-created tabs. They do not modify the XPI or extension resources. The native `browser` namespace remains available to WebKit's event dispatcher; the `chrome` namespace supplies the additional navigation API. This is partial API coverage, not full Firefox compatibility.

The opt-in [production-host smoke test](../Tests/BrowseTests/ExtensionCompatibilityTests.swift) imports the verified, unmodified 8.12.41.1 XPI with Bend's actual manager and window/tab bridge. It reaches the welcome page, completes the three optional onboarding choices with “Don't enable” in disposable data, and follows **Sign in** to `https://start.1password.com/signin/?auth-only=1`. The official page renders its **Email → Continue** form. The test supplies a normal-sized viewport; a zero-size windowless website view did not render that form. The tested onboarding run reports no extension context errors. The earlier context-menu failure did not recur in this run; general context-menu compatibility is not established by that observation.

Desktop native messaging remains on WebKit's default transport and is unavailable for this resource package. Its attempts time out before standalone setup proceeds. The user has confirmed that the toolbar shows vault items after authentication. Inline fill, save, unlock after locking, and account persistence still require authenticated testing. The normal user's profile and credentials are not involved in automated tests. Settings describes the Firefox package as experimental and retains the separate unsupported notice for the Safari package.

Two host navigation restrictions explain the reported stale sign-in page and empty inline menu. The verified package's post-authentication handler calls `tabs.update` on the web sign-in tab with its own `/app/app.html#/page/ready` URL; Bend previously rejected all extension URLs in pane updates. Its inline menu is a web-accessible extension iframe, which Bend's navigation delegate also rejected. The host now allows loaded extension subframes under WebKit's resource checks and transitions authorized tab updates to context-configured views while retaining tab identity. A normal WKWebView alone cannot load an extension top-level document: WebKit's `WebExtensionURLSchemeHandlerCocoa.mm` checks the configuration's required extension origin. Returning to a website therefore restores an ordinary view. Account-free regression tests reproduce both original failures and verify the transitions, messaging, resource boundary, restoration, and disable cleanup. They do not establish real vault-item filling.

## Proposed runtime work

1. Keep WKWebExtension for resource loading, content-script isolation, permissions, storage, and declarative rules. Build an opt-in real-package compatibility harness with isolated profiles and explicit assertions for background readiness, popup functionality, local-form filling, and restart behavior.
2. For each API gap, establish whether the installed public WebKit APIs can support it. Implement full behavior and permission checks where possible. For notifications and navigation-target events, compare a host-level implementation with a narrow WebKit change. Prototype against the checkout before choosing a bundled engine; account for signing, subprocess packaging, licensing, and security updates.
3. Implement standard native messaging through the public delegate callbacks: host-manifest discovery, allowed-extension checks, bounded framed JSON transport, process lifetime, and disconnection. Test using a purpose-built host before attempting 1Password's companion. Do not impersonate another browser or weaken 1Password's signature checks.
4. Add authenticated catalog installation and updates separately: verified download provenance, package identity, integrity/signature handling, explicit permission increases, and rollback. The current local-file installer is not that supply chain.
5. Validate 1Password and full uBlock Origin separately. uBlock Origin Lite is a distinct extension and cannot serve as proof of full uBlock Origin compatibility.

The next runtime milestone is a functioning 1Password startup and sign-in UI in an isolated profile. Unlock, fill, save, and desktop-app integration remain separate acceptance checks. A successful package load alone is insufficient.
