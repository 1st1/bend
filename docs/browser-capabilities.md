# Browser capability verification and remaining integration

Bend's packaged app supplies camera, microphone, and location usage descriptions. Camera and microphone require the signed entitlements in scripts/Bend.entitlements. Run checks on macOS 26 and 27; a SwiftPM test executable cannot replace signed-app privacy testing.

## Manual verification

Build with ./scripts/build-app.sh, then launch the isolated diagnostic window:

    "dist/Bend Debug.app/Contents/MacOS/Bend" --diagnose-web-capabilities

The diagnostic uses an ephemeral website store and a synthetic HTTPS origin. It does not restore browser tabs, contact a test website, record media, or transmit captured media. Every capture starts from a button and requires ordinary WebKit/macOS permissions. Camera preview is muted. Close the window or select Stop all capture to end tracks.

Check camera and microphone independently, then together. Test both permission denial and approval. For screen sharing, cancel the chooser first, then select a window containing only test content. Confirm a video track, stop from the system sharing control, and verify the track-ended report. Repeat for a display only if desired. Audio support is established only when an audio track is actually returned; requesting audio does not guarantee it.

Verify single-file, multiple-file, and folder selection. Cancel a picker, hide the page, navigate away, and close the window while a picker is open. The callback must finish once and must not deliver files to a replacement document.

In the normal browser, check the header's capture indicator while switching tabs and panes. Stop camera/microphone from the header, and block access from the shield menu. Compare HTTPS origins with different ports and subdomains. Choose Remember my choice on a permission prompt, then inspect Ask/Allow/Block in Settings → Websites. Reopen Bend to check persisted choices; repeat in a private window to confirm temporary settings. Location blocking applies to subsequent requests; reload the document to end a location watch.

Use a real HTTPS site, such as the Zoom test call, for the final screen-sharing test. The synthetic diagnostic cannot establish service-worker registration, push delivery, passkey registration, or compatibility with a particular conferencing service.

## Observed verification

On macOS 27.2.1, the signed diagnostic exposed getUserMedia and getDisplayMedia. Selecting the diagnostic window produced a video track, and Stop all capture stopped it. No audio track was returned for this window-sharing request. PushManager was absent, and the platform authenticator availability check returned false in the unentitled build. These observations do not establish macOS 26 behavior or a live Zoom call.

## Passkeys: Apple approval required

The source includes a signing-entitlement gate and authorization UI under Settings → Websites. It calls ASAuthorizationWebBrowserPublicKeyCredentialManager only when the running signature contains com.apple.developer.web-browser.public-key-credential. Unentitled builds omit the Passkeys settings section. The ordinary app signature deliberately does not claim Apple's managed entitlement without approval.

The organization's Apple Developer Account Holder must submit:
https://developer.apple.com/contact/request/macos-browsers-passkeys/

Application description draft:

> Bend is a general-purpose macOS web browser using WKWebView. It supports arbitrary HTTP and HTTPS navigation, URL entry, web search, bookmarks, tabs, and independent browsing panes. HTTP/HTTPS links navigate directly to the requested content. We request browser passkey support so users can register and authenticate with passkeys on arbitrary websites rendered by WebKit, using Apple's native authorization UI.

Production bundle ID: dev.yury.browse.prototype.
Development bundle ID: dev.yury.browse.debug.
Request coverage for both identifiers if testing requires both.

After approval, create/download matching provisioning profiles and configure both local and CI signing to embed the appropriate profile and sign with the approved entitlement, retaining the camera and audio-input entitlements. The production timestamp re-signing step must retain these entitlements as well. Do not ship until codesign inspection, authorization-denied/allowed flows, and registration/sign-in on a test relying party pass.

Apple documentation:
- https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.web-browser.public-key-credential
- https://developer.apple.com/documentation/authenticationservices/asauthorizationwebbrowserpublickeycredentialmanager

## Website notifications and background push

Website notifications remain unimplemented. The existing ExtensionNotifications class is an extension API adapter, not a website Notification or service-worker Push implementation.

The installed public WKUIDelegate and WKWebsiteDataStore headers do not expose a complete website-notification provider or push-host lifecycle. WebKit's private interfaces include notification-manager and pending-push processing entry points; their presence is not evidence that an arbitrary host has a supported background push service. Simply enabling PushAPIEnabled or replacing window.Notification would advertise behavior the browser cannot deliver.

A complete integration must cover origin permission storage, native notification delivery, click/close routing to the correct page or service worker, tag replacement, site-data removal, private-mode behavior, and delivery/relaunch when Bend is closed. It also requires confirming the supported APNs/webpushd entitlement and provisioning route for a third-party macOS host. These are unresolved prerequisites, not covered by the camera/microphone entitlements.

Sources inspected:
- https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKWebsiteDataStorePrivate.h
- https://github.com/WebKit/WebKit/blob/main/Source/WTF/Scripts/Preferences/UnifiedWebPreferences.yaml
- https://developer.apple.com/documentation/usernotifications/sending-web-push-notifications-in-web-apps-and-browsers
