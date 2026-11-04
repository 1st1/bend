# Independent extensions on WebKit

Browse can own extension installation, permissions, updates, and storage while retaining WebKit. Package management and runtime API compatibility are separate responsibilities. This document records research and proposed next steps, not a claim that 1Password works.

## Other browsers

[Orion](https://help.kagi.com/orion/browser-extensions/macos-extensions.html) installs Chrome and Firefox extensions and maintains its own WebExtensions API compatibility implementation. Its documentation describes substantial API-by-API engineering and incomplete coverage. Its implementation is [not currently open source](https://orionbrowser.com/help), so it is a behavioral reference rather than a reusable implementation.

[Orion's 1Password integration](https://help.kagi.com/orion/browser-extensions/1password.html) involved collaboration with 1Password and requires desktop-app browser authorization. This demonstrates that WebKit is not inherently incompatible with 1Password; it does not establish compatibility for a different host. [1Password's additional-browser requirements](https://support.1password.com/additional-browsers/) describe Chrome/Firefox extension support and Apple code signing on macOS.

[GNOME Web's extension manager](https://github.com/GNOME/epiphany/blob/master/src/webextension/ephy-web-extension-manager.c) installs XPI packages or copied folders into its profile. It owns background and popup views and dispatches extension calls to browser API handlers, including notifications, tabs, and runtime. This is a concrete open-source example of an independent extension host over WebKitGTK. Its GLib/GTK APIs are not directly interchangeable with Cocoa WKWebView. The source is GPL-3.0-or-later; this research does not copy its implementation into Browse.

## Findings in the WebKit checkout

The inspected checkout is `/Users/yury/dev/WebKit`, revision `f91ce22de4`, dated 2026-11-03. No modifications were made to that checkout.

- `Source/WebKit/UIProcess/Extensions/WebExtension.cpp`, `processFileAndExtractZipArchive`: WebKit reads ZIP packages and strips CRX headers before extraction. An XPI is a ZIP package. Reading these formats does not establish publisher authenticity or full Chrome/Firefox API compatibility.
- `Source/WebKit/WebProcess/Extensions/Interfaces/WebExtensionAPINotifications.idl` and `Source/WebKit/WebProcess/Extensions/API/Cocoa/WebExtensionAPINotificationsCocoa.mm`: notification API implementation exists in this checkout.
- `Source/WTF/Scripts/Preferences/UnifiedWebPreferences.yaml`, `WebExtensionNotificationsEnabled`: notifications are disabled by default behind a testable feature flag. `WebExtensionAPINamespace.cpp` also requires the extension's notification permission.
- `Source/WebKit/UIProcess/Extensions/Cocoa/API/WebExtensionContextAPINotificationsCocoa.mm`: presenting notifications requires the private `_webExtensionController:presentNotification:forExtensionContext:completionHandler:` delegate. Merely enabling the flag would not provide a working notification service. Availability in this checkout does not guarantee availability in the installed system framework.
- `Source/WebKit/WebProcess/Extensions/Interfaces/WebExtensionAPIWebNavigation.idl`: the navigation-target-created event used by the Firefox 1Password package is absent.
- `Source/WebKit/UIProcess/Extensions/Cocoa/API/WebExtensionContextAPIRuntimeCocoa.mm`: the default native-message path resolves an installed NSExtension by bundle identifier. Copying Safari resources does not create an independent native companion. Public controller delegate callbacks allow the browser to supply a different native-messaging transport.

## Implemented ownership boundary

Browse uses the system WebKit framework with its own app profile; it does not yet bundle a custom engine. All new imports are copied into Browse's extension directory. Existing externally referenced imports migrate to owned copies while retaining context identities and approved access. Source application updates no longer silently replace installed resources.

Settings supports manual local-package installation, replacement, enablement, removal, and options pages. Updates preserve the extension origin and storage, validate replacement identity where available, and hold additional permissions for review. These are explicitly selected local imports, not authenticated browser-store installs or automatic updates. Declared manifest IDs and keys are identity hints, not publisher verification.

## Proposed runtime work

1. Keep WKWebExtension for resource loading, content-script isolation, permissions, storage, and declarative rules. Build an opt-in real-package compatibility harness with isolated profiles and explicit assertions for background readiness, popup functionality, local-form filling, and restart behavior.
2. For each API gap, establish whether the installed public WebKit APIs can support it. Implement full behavior and permission checks where possible. For notifications and navigation-target events, compare a host-level implementation with a narrow WebKit change. Prototype against the checkout before choosing a bundled engine; account for signing, subprocess packaging, licensing, and security updates.
3. Implement standard native messaging through the public delegate callbacks: host-manifest discovery, allowed-extension checks, bounded framed JSON transport, process lifetime, and disconnection. Test using a purpose-built host before attempting 1Password's companion. Do not impersonate another browser or weaken 1Password's signature checks.
4. Add authenticated catalog installation and updates separately: verified download provenance, package identity, integrity/signature handling, explicit permission increases, and rollback. The current local-file installer is not that supply chain.
5. Validate 1Password and full uBlock Origin separately. uBlock Origin Lite is a distinct extension and cannot serve as proof of full uBlock Origin compatibility.

The next runtime milestone is a functioning 1Password startup and sign-in UI in an isolated profile. Unlock, fill, save, and desktop-app integration remain separate acceptance checks. A successful package load alone is insufficient.
