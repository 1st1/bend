# Privacy

Private browsing lifetimes, storage isolation, and privacy preferences.

See [[lat.md/tests/privacy-tests|Test coverage]].

## Private windows

[[Sources/Browse/BrowserWindows.swift#BrowserWindows#newPrivateWindow]] opens a private window through File → New Private Window or Command-Shift-N, with temporary browsing state isolated from regular windows and other private windows.

[[Sources/Browse/BrowserStore.swift#BrowserStore#historyOwner]] keeps private visits and learned address choices in memory for that window. History, removal, clearing, and reopening closed tabs remain available during its lifetime. [[Sources/Browse/BrowserStore.swift#BrowserStore#stopWindow]] clears history, closed items, layouts, temporary site settings, and download records on closure, and removes the window's shared WebKit website data. Completed downloaded files remain on disk; unfinished downloads are cancelled. Late navigation callbacks cannot repopulate closed private history.

[[Sources/Browse/BrowserStore.swift#BrowserStore#configureWebView]] uses one nonpersistent [[Sources/Browse/BrowserStore.swift#BrowserStore#websiteDataStore|website data store]] for all panes and tabs in a private window. Cookies, local storage, caches, and other website data are shared within that window and isolated from regular browsing and other private windows. Closing or reopening a pane or tab retains the window's login and website data; closing the window clears them. Session storage and back/forward navigation remain scoped to each page session. User-content controllers are separate from regular views. Private windows never read or write session snapshots, history databases, window manifests, or frame autosaves. Shared appearance preferences remain available. Site zoom overrides start from the regular profile's settings but changes stay temporary.

[[Sources/Browse/BrowserFavorites.swift#BrowserStore#favorites]] exposes no favorites in private windows; favorite actions are hidden and rejected. The sidebar and pane headers identify private browsing. Closing the sole private window's final pane closes the window. New-window links from a private window open another private window. Cross-window tab and pane transfers involving private windows are rejected so live views cannot cross window-specific data lifetimes.

[[Sources/Browse/ExtensionManager.swift#ExtensionManager#setPrivateAccess]] persists each installed extension's **Enable in private mode** checkbox, defaulting off for new and legacy records. WebKit's private-data permission controls content scripts, request rules, cookies, and tab visibility. [[Sources/Browse/ExtensionBrowserBridge.swift#ExtensionWindow#isPrivate]] identifies private windows to WebKit; host tab actions and extension menus also enforce the opt-in. Extension-owned panes and action popups are unavailable in private windows even after opt-in. Content scripts, request rules, and actions without popups remain available. Revocation closes popups; reload websites to remove already-injected page changes. Opted-in extensions retain their shared background context and extension-managed storage.

[[Sources/Browse/BrowserStore.swift#BrowserStore#extensionConfiguration]] refuses extension configurations in private windows: their shared website store would expose regular cookies to embedded HTTP content and requests. [[Sources/Browse/BrowserStore.swift#PageController#navigateExtension]] also rejects direct navigation before replacing the private view. Tab creation, tab navigation, and lazy page loading reject extension origins without opening a shared-store view. [[Sources/Browse/ExtensionManager.swift#ExtensionManager#performAction]] and [[Sources/Browse/ExtensionBrowserBridge.swift#ExtensionManager#webExtensionController]] reject private action popups before retrieving WebKit's popup view. Extension settings remain available as separate ordinary extension windows.

[[lat.md/tests/privacy-tests#Private window lifetime]], [[lat.md/tests/privacy-tests#Private window storage sharing]], [[lat.md/tests/privacy-tests#Private window keyboard command]], [[lat.md/tests/extension-hosting/lifecycle-tests#Private extension access]], and [[lat.md/tests/extension-hosting/lifecycle-tests#Private extension iframe isolation]] cover lifetime, persistence exclusion, keyboard routing, and WebKit isolation.

## Privacy preferences

[[Sources/Browse/PrivacySettingsView.swift#PrivacySettingsView]] provides Settings → Privacy with native tracking, payment disclosure, ad measurement, cookie controls, and website-data management.

[[Sources/Browse/WebKitPrivacy.swift#WebKitPrivacy]] isolates capability-checked private WebKit selectors. Cross-site tracking prevention and Apple Pay capability disclosure default on; Private Click Measurement defaults off. Choices persist in the website-settings database, and existing saved choices are preserved. Missing selectors disable their UI controls and are never invoked. Settings affect Bend objects, never Safari preferences. Regular windows share preferences; private windows inherit temporary copies and independent website data stores.

The additional native protection bundle is enabled for all website views before creation and on navigation, including private windows. It requests fingerprinting protections, link filtering, and enhanced network privacy without provisioning a proxy service. Open documents need reloading for navigation protections. Turning ITP off leaves this bundle enabled. Extension documents retain their own policies. Native updates and independent-store behavior are covered by [[lat.md/tests/privacy-tests#Native privacy preferences]].

The green-check list describes origin isolation, temporary private storage, and available additional protections; filtering depends on macOS rules. Bend does not claim anonymity, IP hiding, or full Safari parity. Cookie controls and Manage Website Data live here rather than in Websites.
