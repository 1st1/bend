import AppKit
import CryptoKit
import Network
import Testing
import WebKit
@testable import Browse

@MainActor
func extensionFixture(at root: URL) throws -> URL {
    let source = root.appendingPathComponent("fixture", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data(#"""
    {"manifest_version":3,"name":"Browse Test Extension","version":"1.0",
     "browser_specific_settings":{"gecko":{"id":"browse-fixture@example.test"}},
     "permissions":["storage","tabs","declarativeNetRequest"],"host_permissions":["http://127.0.0.1/*"],
     "content_security_policy":{"extension_pages":"script-src 'self' 'wasm-unsafe-eval'; object-src 'self'"},
     "content_scripts":[{"matches":["http://127.0.0.1/*"],"js":["content.js"],"run_at":"document_end"}],
     "declarative_net_request":{"rule_resources":[{"id":"rules","enabled":true,"path":"rules.json"}]},
     "action":{"default_popup":"popup.html"},"options_ui":{"page":"options.html"}}
    """#.utf8).write(to: source.appendingPathComponent("manifest.json"))
    try Data("document.body.dataset.browseExtension = 'active';".utf8).write(to: source.appendingPathComponent("content.js"))
    try Data(#"[{"id":1,"priority":1,"action":{"type":"block"},"condition":{"urlFilter":"/blocked.js","resourceTypes":["script"]}}]"#.utf8)
        .write(to: source.appendingPathComponent("rules.json"))
    try Data("<body>Popup fixture</body>".utf8).write(to: source.appendingPathComponent("popup.html"))
    try Data("<body>Options fixture</body>".utf8).write(to: source.appendingPathComponent("options.html"))
    return source
}

// @lat: [[tests#Extension lifecycle and permissions]]
@Test @MainActor func extensionLifecycle() async throws {
    guard #available(macOS 15.4, *) else { return }
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseExtensions-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try extensionFixture(at: root)
    let manager = ExtensionManager(root: root.appendingPathComponent("installed"), persistent: false)
    try await manager.importExtension(from: source)
    let record = try #require(manager.records.first)
    #expect(record.source != source)
    #expect(!record.enabled)
    #expect(!manager.isEnabled(record.id))
    try await manager.enable(true, id: record.id) { _, requested in
        #expect(requested.contains("http://127.0.0.1/*"))
        return false
    }
    #expect(!manager.isEnabled(record.id))
    try await manager.enable(true, id: record.id) { _, _ in true }
    #expect(manager.isEnabled(record.id))
    #expect(manager.records[0].enabled)
    let context = try #require(manager.contexts[record.id])
    #expect(context.hasPermission(.init(rawValue: "storage")))
    #expect(context.hasAccess(to: URL(string: "http://127.0.0.1/test")!))
    #expect(!context.hasAccess(to: URL(string: "https://unrelated.example/")!))
    let baseURL = context.baseURL
    try await manager.enable(false, id: record.id) { _, _ in true }
    #expect(!manager.isEnabled(record.id))
    let restored = ExtensionManager(root: manager.root, persistent: false)
    restored.start()
    await restored.restorationTask?.value
    #expect(restored.records[0].permissions.contains("storage"))
    #expect(restored.contexts[record.id]?.baseURL == baseURL)
    #expect(!restored.isEnabled(record.id))
}

// @lat: [[tests#Enabled extension restoration]]
@Test @MainActor func enabledExtensionRestoration() async throws {
    guard #available(macOS 15.4, *) else { return }
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseExtensionRestart-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try extensionFixture(at: root)
    let storageID = UUID()
    let websiteStore = WKWebsiteDataStore(forIdentifier: UUID())
    let installed = root.appendingPathComponent("installed")
    var manager = ExtensionManager(root: installed, storageIdentifier: storageID, websiteDataStore: websiteStore, notifications: TestNotifications())
    try await manager.importExtension(from: source)
    let id = try #require(manager.records.first?.id)
    try await manager.enable(true, id: id) { _, _ in true }
    let origin = try #require(manager.contexts[id]?.baseURL)
    try FileManager.default.removeItem(at: source)
    for launch in 0..<4 {
        let context = try #require(manager.contexts[id])
        #expect(manager.records.first?.enabled == true)
        #expect(manager.isEnabled(id))
        #expect(manager.failures.isEmpty)
        #expect(context.baseURL == origin)
        var web: WKWebView? = WKWebView(frame: .zero, configuration: try #require(context.webViewConfiguration))
        let navigation = ExtensionTestNavigation()
        web?.navigationDelegate = navigation
        try await navigation.load(try #require(web), url: try #require(context.optionsPageURL))
        let result = try await web?.callAsyncJavaScript("""
            const saved = (await browser.storage.local.get('restartMarker')).restartMarker;
            await browser.storage.local.set({restartMarker: iteration});
            return saved ?? -1;
            """, arguments: ["iteration": launch], in: nil, contentWorld: .page)
        #expect(result as? Int == launch - 1)
        let encrypted = try await web?.callAsyncJavaScript(#"""
            const db = await new Promise((resolve, reject) => {
                const request = indexedDB.open('browse-fixture-persistence', 1);
                request.onupgradeneeded = () => request.result.createObjectStore('state');
                request.onsuccess = () => resolve(request.result); request.onerror = () => reject(request.error);
            });
            const previous = await new Promise((resolve, reject) => {
                const request = db.transaction('state').objectStore('state').get('encrypted');
                request.onsuccess = () => resolve(request.result); request.onerror = () => reject(request.error);
            });
            let decrypted = -1;
            if (previous) decrypted = Number(new TextDecoder().decode(await crypto.subtle.decrypt({name:'AES-GCM', iv:previous.iv}, previous.key, previous.data)));
            const key = previous?.key ?? await crypto.subtle.generateKey({name:'AES-GCM',length:256}, false, ['encrypt','decrypt']);
            const iv = crypto.getRandomValues(new Uint8Array(12));
            const data = await crypto.subtle.encrypt({name:'AES-GCM',iv}, key, new TextEncoder().encode(String(iteration)));
            await new Promise((resolve, reject) => {
                const transaction = db.transaction('state','readwrite');
                transaction.objectStore('state').put({key,iv,data}, 'encrypted');
                transaction.oncomplete = resolve; transaction.onerror = () => reject(transaction.error);
            });
            db.close();
            const local = Number(localStorage.getItem('fixture-marker') ?? -1);
            localStorage.setItem('fixture-marker', String(iteration));
            return {decrypted,local};
            """#, arguments: ["iteration": launch], in: nil, contentWorld: .page) as? [String: Int]
        #expect(encrypted?["decrypted"] == launch - 1)
        #expect(encrypted?["local"] == launch - 1)
        web = nil
        // End runtime without disabling the persisted user preference.
        try manager.controller.unload(context)
        manager = ExtensionManager(root: installed, storageIdentifier: storageID, websiteDataStore: websiteStore, notifications: TestNotifications())
        manager.start()
        await manager.restorationTask?.value
    }
    try await manager.uninstall(id)
}

// @lat: [[tests#uBlock origin migration and isolation]]
@Test @MainActor func uBlockOriginMigrationAndIsolation() async throws {
    guard #available(macOS 15.4, *) else { return }
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseUBlockOrigin-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try extensionFixture(at: root)
    let manifestURL = fixture.appendingPathComponent("manifest.json")
    var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
    manifest["permissions"] = ["storage", "privacy"]
    try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
    let source = root.appendingPathComponent("UBlockFixture.appex")
    let contents = source.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: fixture, to: contents.appendingPathComponent("Resources"))
    let bundleInfo: [String: Any] = [
        "CFBundleIdentifier": "net.raymondhill.uBlock-Origin-Lite.Extension",
        "CFBundlePackageType": "XPC!", "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0",
        "NSExtension": ["NSExtensionPointIdentifier": "com.apple.Safari.web-extension"]
    ]
    try PropertyListSerialization.data(fromPropertyList: bundleInfo, format: .xml, options: 0)
        .write(to: contents.appendingPathComponent("Info.plist"))
    // WebKit validates resources in Safari bundles, including test fixtures.
    let signer = Process()
    signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    signer.arguments = ["--force", "--sign", "-", "--timestamp=none", source.path]
    try signer.run()
    signer.waitUntilExit()
    try #require(signer.terminationStatus == 0)
    let storageID = UUID()
    let websiteStore = WKWebsiteDataStore(forIdentifier: UUID())
    let installed = root.appendingPathComponent("installed")
    var manager = ExtensionManager(root: installed, storageIdentifier: storageID, websiteDataStore: websiteStore,
        notifications: TestNotifications())
    try await manager.importExtension(from: source)
    let id = try #require(manager.records.first?.id)
    let legacy = try #require(manager.contexts[id])
    // Seed the prior release's real origin and persistent browser.storage namespace.
    legacy.baseURL = URL(string: "webkit-extension://\(id.uuidString.lowercased())/")!
    try await manager.enable(true, id: id) { _, _ in true }
    let oldOptions = legacy.baseURL.appendingPathComponent("options.html").appending(queryItems: [URLQueryItem(name: "source", value: "saved")])
    var web: WKWebView? = WKWebView(frame: .zero, configuration: try #require(legacy.webViewConfiguration))
    let navigation = ExtensionTestNavigation()
    web?.navigationDelegate = navigation
    try await navigation.load(try #require(web), url: oldOptions)
    _ = try await web?.callAsyncJavaScript("await browser.storage.local.set({filteringMode: 2, customFilters: ['example.test##.ad']});", arguments: [:], in: nil, contentWorld: .page)
    web = nil
    try manager.controller.unload(legacy)
    manager = ExtensionManager(root: installed, storageIdentifier: storageID, websiteDataStore: websiteStore,
        notifications: TestNotifications())
    manager.start()
    await manager.restorationTask?.value
    let context = try #require(manager.contexts[id])
    defer { if context.isLoaded { try? manager.controller.unload(context) } }
    #expect(context.baseURL.scheme == "safari-web-extension")
    #expect(context.uniqueIdentifier == legacy.uniqueIdentifier)
    #expect(context.baseURL.host == legacy.baseURL.host)
    #expect(manager.isEnabled(id))
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), extensionManager: manager)
    store.session.workspaces[0].tabs[0].pages[0].address = oldOptions.absoluteString
    let restored = store.controller(for: store.selectedTab.pages[0])
    for _ in 0..<50 {
        if restored.webView.url?.scheme == "safari-web-extension", !restored.webView.isLoading { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    #expect(restored.webView.url == manager.restoredExtensionURL(oldOptions))
    let settings = try await restored.webView.callAsyncJavaScript("return await browser.storage.local.get(null);", arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
    #expect(settings?["filteringMode"] as? Int == 2)
    #expect(settings?["customFilters"] as? [String] == ["example.test##.ad"])
    // The compatibility bridge must remain available and authorized on the new origin.
    let privacy = try await restored.webView.callAsyncJavaScript("return (await chrome.privacy.services.passwordSavingEnabled.get({})).value;", arguments: [:], in: nil, contentWorld: .page)
    #expect(privacy as? Bool == false)
    #expect(try await restored.webView.evaluateJavaScript("browser.runtime.getURL('options.html').startsWith('safari-web-extension:')") as? Bool == true)
    // A lookalike display name must not opt another package into this behavior.
    manifest["name"] = "uBlock Origin Lite"
    manifest["browser_specific_settings"] = ["gecko": ["id": "unrelated@example.test"]]
    try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
    let otherSource = root.appendingPathComponent("unrelated")
    try FileManager.default.copyItem(at: fixture, to: otherSource)
    try await manager.importExtension(from: otherSource)
    let other = try #require(manager.records.first { $0.id != id })
    #expect(manager.contexts[other.id]?.baseURL.scheme == "webkit-extension")
    let otherURL = try #require(manager.contexts[other.id]?.baseURL).appendingPathComponent("options.html")
    #expect(manager.restoredExtensionURL(otherURL) == otherURL)
    #expect(ExtensionManager.usesSafariOrigin("safari:net.raymondhill.uBlock-Origin-Lite.Extension"))
    #expect(!ExtensionManager.usesSafariOrigin("gecko:uBlock0@raymondhill.net"))
    #expect(!ExtensionManager.usesSafariOrigin("gecko:uBOLiteRedux@raymondhill.net"))
    try await manager.uninstall(id)
    try await manager.uninstall(other.id)
}

// @lat: [[tests#Extension startup content injection]]
@Test @MainActor func extensionStartupContentInjection() async throws {
    guard #available(macOS 15.4, *) else { return }
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseExtensionStartup-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try extensionFixture(at: root)
    let installed = root.appendingPathComponent("installed")
    let setup = ExtensionManager(root: installed, persistent: false)
    try await setup.importExtension(from: source)
    let id = try #require(setup.records.first?.id)
    try await setup.enable(true, id: id) { _, _ in true }
    try setup.controller.unload(try #require(setup.contexts[id]))
    let server = try await ExtensionHTTPFixture.start()
    defer { server.listener.cancel() }
    for _ in 0..<4 {
        let manager = ExtensionManager(root: installed, persistent: false)
        let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), extensionManager: manager)
        store.newTab(address: "http://127.0.0.1:\(server.port)/")
        let page = store.controller(for: store.selectedTab.pages[0])
        for _ in 0..<100 {
            if (try? await page.webView.evaluateJavaScript("document.body?.dataset.browseExtension")) as? String == "active" { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        await manager.restorationTask?.value
        #expect(manager.isEnabled(id))
        #expect(try await page.webView.evaluateJavaScript("document.body.dataset.browseExtension") as? String == "active")
        #expect(try await page.webView.evaluateJavaScript("window.blockedScriptRan === true") as? Bool == false)
        try manager.controller.unload(try #require(manager.contexts[id]))
    }
}

// @lat: [[tests#Firefox extension restoration smoke test]]
@Test @MainActor func firefoxExtensionRestorationSmoke() async throws {
    guard #available(macOS 15.4, *), let path = ProcessInfo.processInfo.environment["BROWSE_TEST_FIREFOX_PACKAGE"] else { return }
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseFirefoxRestart-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let storageID = UUID()
    let websiteStore = WKWebsiteDataStore(forIdentifier: UUID())
    let installed = root.appendingPathComponent("installed")
    var manager = ExtensionManager(root: installed, storageIdentifier: storageID, websiteDataStore: websiteStore, notifications: TestNotifications())
    manager.presentsWindows = false
    manager.nativeMessaging.resolve = { _, _ in NativeHost(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: []) }
    try await manager.importExtension(from: URL(fileURLWithPath: path))
    let id = try #require(manager.records.first?.id)
    try await manager.enable(true, id: id) { _, _ in true }
    let origin = try #require(manager.contexts[id]?.baseURL)
    try manager.controller.unload(try #require(manager.contexts[id]))
    for _ in 0..<3 {
        manager = ExtensionManager(root: installed, storageIdentifier: storageID, websiteDataStore: websiteStore, notifications: TestNotifications())
        manager.presentsWindows = false
        manager.nativeMessaging.resolve = { _, _ in NativeHost(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: []) }
        let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), extensionManager: manager)
        await manager.restorationTask?.value
        _ = store.controller(for: store.selectedTab.pages[0])
        let context = try #require(manager.contexts[id])
        #expect(manager.records.first?.enabled == true)
        #expect(manager.isEnabled(id))
        #expect(manager.failures.isEmpty)
        #expect(context.baseURL == origin)
        try await context.loadBackgroundContent()
        try await Task.sleep(for: .seconds(8))
        #expect(context.errors.isEmpty)
        manager.performAction(id, pageID: store.selectedTab.focusedPane)
        for _ in 0..<100 where manager.documents.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        let document = try #require(manager.documents.values.first)
        var onboardingVisible = false
        for _ in 0..<100 {
            let text = (try? await document.web.evaluateJavaScript("document.body?.innerText")) as? String ?? ""
            if text.contains("Welcome to 1Password") { onboardingVisible = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(onboardingVisible)
        manager.closeDocuments(for: context)
        try manager.controller.unload(context)
    }
    try await manager.uninstall(id)
}

// @lat: [[tests#Extension content injection and blocking]]
@Test @MainActor func extensionContentAndBlocking() async throws {
    guard #available(macOS 15.4, *) else { return }
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseExtensionRuntime-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try extensionFixture(at: root)
    let server = try await ExtensionHTTPFixture.start()
    defer { server.listener.cancel() }
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    let manager = store.extensions
    let initialPaneCount = store.session.workspaces.flatMap(\.tabs).flatMap(\.pages).count
    try await manager.importExtension(from: source)
    let id = try #require(manager.records.first?.id)
    try await manager.enable(true, id: id) { _, _ in true }
    let page = store.selectedTab.pages[0]
    let pageController = store.controller(for: page)
    let web = pageController.webView
    let navigation = ExtensionTestNavigation()
    web.navigationDelegate = navigation
    let url = URL(string: "http://127.0.0.1:\(server.port)/")!
    try await navigation.load(web, url: url)
    #expect(try await web.evaluateJavaScript("document.body.dataset.browseExtension") as? String == "active")
    #expect(try await web.evaluateJavaScript("window.blockedScriptRan === true") as? Bool == false)
    let context = try #require(manager.contexts[id])
    #expect(manager.window.tabs(for: context).count == initialPaneCount)
    #expect(manager.window.activeTab(for: context) === manager.tabs[page.id])
    #expect(manager.tabs[page.id]?.webView(for: context) === web)
    store.split(.horizontal)
    #expect(manager.window.tabs(for: context).count == initialPaneCount + 1)
    #expect(manager.window.activeTab(for: context) === manager.tabs[store.selectedTab.focusedPane])
    store.closePage(page.id)
    #expect(manager.tabs[page.id] == nil)
    try await manager.enable(false, id: id) { _, _ in true }
    try await navigation.load(web, url: url)
    #expect(try await web.evaluateJavaScript("document.body.dataset.browseExtension || ''") as? String == "")
    #expect(try await web.evaluateJavaScript("window.blockedScriptRan === true") as? Bool == true)
}

// @lat: [[tests#Extension update permissions and resource pages]]
@Test @MainActor func extensionUpdatesAndPages() async throws {
    guard #available(macOS 15.4, *) else { return }
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseExtensionUpdate-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try extensionFixture(at: root)
    let manager = ExtensionManager(root: root.appendingPathComponent("installed"), persistent: false)
    try await manager.importExtension(from: source)
    let record = try #require(manager.records.first)
    try await manager.enable(true, id: record.id) { _, _ in true }
    let context = try #require(manager.contexts[record.id])
    let configuration = try #require(context.webViewConfiguration)
    let document = ExtensionDocument(manager: manager, context: context, configuration: configuration)
    // Exercise the extension's real document and API namespace without displaying a window.
    let navigation = ExtensionTestNavigation()
    document.web.navigationDelegate = navigation
    try await navigation.load(document.web, url: try #require(context.optionsPageURL))
    #expect(try await document.web.evaluateJavaScript("browser.runtime.id") as? String == record.id.uuidString)
    #expect(try await document.web.evaluateJavaScript("document.body.textContent") as? String == "Options fixture")
    #expect(document.webView(for: context) === document.web)
    // Check runtime primitives separately from a third-party extension's startup.
    let capabilities = try await document.web.callAsyncJavaScript(#"""
        await WebAssembly.instantiate(new Uint8Array([0,97,115,109,1,0,0,0]));
        const database = await new Promise((resolve, reject) => {
            const request = indexedDB.open('BrowseTest');
            request.onupgradeneeded = () => request.result.createObjectStore('values');
            request.onsuccess = () => resolve(request.result);
            request.onerror = () => reject(request.error);
        });
        try {
            await new Promise((resolve, reject) => {
                const transaction = database.transaction('values', 'readwrite');
                transaction.objectStore('values').put('saved', 'key');
                transaction.oncomplete = resolve;
                transaction.onerror = () => reject(transaction.error);
                transaction.onabort = () => reject(transaction.error);
            });
            return await new Promise((resolve, reject) => {
                const request = database.transaction('values').objectStore('values').get('key');
                request.onsuccess = () => resolve(request.result);
                request.onerror = () => reject(request.error);
            });
        } finally { database.close(); }
        """#, arguments: [:], in: nil, contentWorld: .page)
    #expect(capabilities as? String == "saved")

    let manifest = record.source.appendingPathComponent("manifest.json")
    var updated = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
    updated["host_permissions"] = ["http://127.0.0.1/*", "https://new-access.example/*"]
    try JSONSerialization.data(withJSONObject: updated).write(to: manifest)
    let restored = ExtensionManager(root: manager.root, persistent: false)
    restored.start()
    await restored.restorationTask?.value
    #expect(!restored.isEnabled(record.id))
    #expect(restored.failures[record.id] != nil)
    #expect(restored.contexts[record.id]?.hasAccess(to: URL(string: "https://new-access.example/")!) == false)
    try await manager.enable(false, id: record.id) { _, _ in true }
    document.nativeWindow.close()
}

// @lat: [[tests#Owned extension packages and updates]]
@Test @MainActor func extensionOwnedPackages() async throws {
    guard #available(macOS 15.4, *) else { return }
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseOwnedPackages-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try extensionFixture(at: root)
    let archive = root.appendingPathComponent("fixture.xpi")
    let zip = Process()
    zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    zip.arguments = ["-q", "-r", archive.path, "."]
    zip.currentDirectoryURL = source
    try zip.run(); zip.waitUntilExit()
    #expect(zip.terminationStatus == 0)
    // Exercise production persistence in a unique profile, never the user's store.
    let storageIdentifier = UUID()
    let manager = ExtensionManager(root: root.appendingPathComponent("installed"), storageIdentifier: storageIdentifier)
    try await manager.importExtension(from: archive)
    let record = try #require(manager.records.first)
    #expect(manager.ownsPackage(record))
    #expect(record.importedFrom == archive)
    #expect(record.packageIdentifier == "gecko:browse-fixture@example.test")
    try await manager.enable(true, id: record.id) { _, _ in true }
    let origin = manager.contexts[record.id]?.baseURL
    let before = try #require(manager.contexts[record.id])
    var web: WKWebView? = WKWebView(frame: .zero, configuration: try #require(before.webViewConfiguration))
    let navigation = ExtensionTestNavigation()
    web?.navigationDelegate = navigation
    try await navigation.load(try #require(web), url: try #require(before.optionsPageURL))
    _ = try await web?.callAsyncJavaScript("await browser.storage.local.set({updateMarker: 'retained'});", arguments: [:], in: nil, contentWorld: .page)
    web = nil
    try FileManager.default.removeItem(at: archive)
    #expect(FileManager.default.fileExists(atPath: record.source.path))

    let manifest = source.appendingPathComponent("manifest.json")
    var updated = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
    updated["version"] = "2.0"
    try JSONSerialization.data(withJSONObject: updated).write(to: manifest)
    try await manager.replacePackage(record.id, from: source)
    #expect(manager.isEnabled(record.id))
    #expect(manager.contexts[record.id]?.baseURL == origin)
    #expect(manager.contexts[record.id]?.webExtension.version == "2.0")
    let after = try #require(manager.contexts[record.id])
    web = WKWebView(frame: .zero, configuration: try #require(after.webViewConfiguration))
    web?.navigationDelegate = navigation
    try await navigation.load(try #require(web), url: try #require(after.optionsPageURL))
    let marker = try await #require(web).callAsyncJavaScript("return (await browser.storage.local.get('updateMarker')).updateMarker;", arguments: [:], in: nil, contentWorld: .page)
    let storedValue = marker as? String
    #expect(storedValue == "retained")
    web = nil
    #expect(!FileManager.default.fileExists(atPath: record.source.path))
    let current = manager.records[0].source

    updated["browser_specific_settings"] = ["gecko": ["id": "different@example.test"]]
    try JSONSerialization.data(withJSONObject: updated).write(to: manifest)
    do {
        try await manager.replacePackage(record.id, from: source)
        Issue.record("An update with a different extension identity was accepted")
    } catch {}
    #expect(manager.records[0].source == current)
    #expect(manager.isEnabled(record.id))
    let invalid = root.appendingPathComponent("broken.zip")
    try Data("not an archive".utf8).write(to: invalid)
    do {
        try await manager.replacePackage(record.id, from: invalid)
        Issue.record("An invalid update was accepted")
    } catch {}
    #expect(manager.records[0].source == current)
    #expect(manager.isEnabled(record.id))

    updated["browser_specific_settings"] = ["gecko": ["id": "browse-fixture@example.test"]]
    updated["host_permissions"] = ["http://127.0.0.1/*", "https://new-access.example/*"]
    try JSONSerialization.data(withJSONObject: updated).write(to: manifest)
    try await manager.replacePackage(record.id, from: source)
    #expect(!manager.isEnabled(record.id))
    #expect(manager.failures[record.id] != nil)
    #expect(manager.contexts[record.id]?.hasAccess(to: URL(string: "https://new-access.example/")!) == false)
    let restored = ExtensionManager(root: manager.root, storageIdentifier: storageIdentifier)
    restored.start(); await restored.restorationTask?.value
    #expect(restored.contexts[record.id]?.baseURL == origin)
    #expect(!restored.isEnabled(record.id))
    try await manager.uninstall(record.id)
    #expect(manager.records.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: manager.root.appendingPathComponent(record.id.uuidString).path))
    #expect(FileManager.default.fileExists(atPath: manifest.path))
}

// @lat: [[tests#Extension package migration and isolation]]
@Test @MainActor func extensionPackageMigration() async throws {
    guard #available(macOS 15.4, *) else { return }
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowsePackageMigration-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try extensionFixture(at: root)
    try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("internal.js").path, withDestinationPath: "content.js")
    let installed = root.appendingPathComponent("installed")
    try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
    let legacy = ExtensionRecord(id: UUID(), source: source, isBundle: false, name: "Legacy", permissions: ["storage"])
    try JSONEncoder().encode([legacy]).write(to: installed.appendingPathComponent("extensions.json"))
    let manager = ExtensionManager(root: installed, persistent: false)
    manager.start(); await manager.restorationTask?.value
    let record = try #require(manager.records.first)
    #expect(record.id == legacy.id)
    #expect(record.permissions == legacy.permissions)
    #expect(record.source != source)
    #expect(manager.ownsPackage(record))
    try FileManager.default.removeItem(at: source)
    #expect(try String(contentsOf: record.source.appendingPathComponent("internal.js"), encoding: .utf8).contains("browseExtension"))
    let restored = ExtensionManager(root: installed, persistent: false)
    restored.start(); await restored.restorationTask?.value
    #expect(restored.contexts[record.id] != nil)
    #expect(restored.failures.isEmpty)

    let unsafeSource = try extensionFixture(at: root.appendingPathComponent("unsafe"))
    try FileManager.default.createSymbolicLink(at: unsafeSource.appendingPathComponent("outside"), withDestinationURL: installed)
    do {
        try await manager.importExtension(from: unsafeSource)
        Issue.record("A package containing an external symbolic link was accepted")
    } catch {}
    #expect(manager.records.count == 1)
}

@MainActor
final class ExtensionTestNavigation: NSObject, WKNavigationDelegate {
    var continuation: CheckedContinuation<Void, Error>?
    func load(_ web: WKWebView, url: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            web.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume(); continuation = nil
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error); continuation = nil
    }
}

// @lat: [[tests#Catalog download integrity and identity]]
@Test @MainActor func catalogIntegrityAndIdentity() async throws {
    let data = Data("package fixture".utf8)
    let url = URL(string: "https://example.test/extension.xpi")!
    let download = CatalogDownload(version: "1", url: url,
        sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
    try download.validate(data, response: response)
    #expect(throws: CatalogError.self) { try download.validate(Data("changed".utf8), response: response) }
    #expect(throws: CatalogError.self) { try download.validate(Data(), response: response) }
    #expect(throws: CatalogError.self) {
        try download.validate(data, response: HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
    }
    #expect(throws: CatalogError.self) {
        try download.validate(data, response: HTTPURLResponse(url: URL(string: "http://example.test/package")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    #expect(throws: CatalogError.self) {
        try download.validate(Data(count: CatalogDownload.maximumBytes + 1), response: response)
    }
    guard #available(macOS 15.4, *) else { return }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseCatalogTest-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try extensionFixture(at: root)
    let manager = ExtensionManager(root: root.appendingPathComponent("installed"), persistent: false)
    do {
        try await manager.importExtension(from: source, expectedIdentifier: CatalogExtension.curated[1].packageIdentifier)
        Issue.record("A mismatched catalog identity was accepted")
    } catch { }
    #expect(manager.records.isEmpty)
    let leftovers = FileManager.default.enumerator(at: manager.root, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? []
    #expect(try leftovers.filter { $0.standardizedFileURL != manager.diagnostics.file.standardizedFileURL }
        .allSatisfy { try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile != true })
    try await manager.importExtension(from: source, expectedIdentifier: "gecko:browse-fixture@example.test")
    let record = try #require(manager.records.first)
    #expect(!manager.isEnabled(record.id))
    #expect(record.permissions.isEmpty)
    #expect(record.websites.isEmpty)
    #expect(manager.catalogRecord(CatalogExtension.curated[1]) == nil)
}

// @lat: [[tests#Catalog package download smoke test]]
@Test(arguments: ["1password", "dark-reader"]) @MainActor func catalogDownloadSmoke(entryID: String) async throws {
    guard #available(macOS 15.4, *), ProcessInfo.processInfo.environment["BROWSE_TEST_CATALOG_DOWNLOAD"] == "1" else { return }
    let entry = try #require(CatalogExtension.curated.first { $0.id == entryID })
    let download = entry.download
    let data = try await download.fetch()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseCatalogDownload-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("official.xpi")
    try data.write(to: source)
    let manager = ExtensionManager(root: root.appendingPathComponent("installed"), persistent: false)
    try await manager.importExtension(from: source, expectedIdentifier: entry.packageIdentifier)
    let record = try #require(manager.catalogRecord(entry))
    #expect(!manager.isEnabled(record.id))
    #expect(manager.contexts[record.id]?.webExtension.version == download.version)
}

final class ExtensionHTTPFixture: @unchecked Sendable {
    let listener: NWListener
    var port: UInt16 { listener.port!.rawValue }
    init() throws { listener = try NWListener(using: .tcp, on: .any) }
    static func start(scriptPath: String = "/blocked.js") async throws -> ExtensionHTTPFixture {
        let server = try ExtensionHTTPFixture()
        server.listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                let request = String(data: data ?? Data(), encoding: .utf8) ?? ""
                let script = request.hasPrefix("GET \(scriptPath) ")
                let userAgent = request.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("user-agent:") } ?? ""
                let encodedAgent = (try? JSONSerialization.data(withJSONObject: userAgent, options: .fragmentsAllowed))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "null"
                let body = script ? "window.blockedScriptRan = true;" : "<html><body>Fixture<script>window.requestUserAgent=\(encodedAgent)</script><script src='\(scriptPath)'></script></body></html>"
                let type = script ? "text/javascript" : "text/html"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nCache-Control: no-store\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            server.listener.stateUpdateHandler = { state in
                switch state {
                case .ready: server.listener.stateUpdateHandler = nil; continuation.resume()
                case .failed(let error): server.listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            server.listener.start(queue: .global())
        }
        return server
    }
}

// @lat: [[tests#Build bundle publication]]
@Test func buildBundlePublication() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [root.appendingPathComponent("scripts/test-build-app.sh").path]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
}

// @lat: [[tests#Production installer publication]]
@Test func productionInstallerPublication() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [root.appendingPathComponent("scripts/test-build-prod.sh").path]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
}

// @lat: [[tests#Private extension access]]
@Test(arguments: [false, true]) @MainActor func privateExtensionAccess(createdBeforeEnable: Bool) async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowsePrivateExtension-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let owner = BrowserWindows(root: root, persistentExtensions: false)
    owner.restore(show: false)
    let regular = try #require(owner.active)
    let earlyPrivateWindow = createdBeforeEnable ? owner.newPrivateWindow(show: false) : nil
    defer { for window in owner.windows { window.window.close() } }
    let manager = owner.sharedStore.extensions
    let source = try extensionFixture(at: root)
    try await manager.importExtension(from: source)
    let id = try #require(manager.records.first?.id)
    try await manager.enable(true, id: id) { _, _ in true }
    let privateWindow = earlyPrivateWindow ?? owner.newPrivateWindow(show: false)
    let context = try #require(manager.contexts[id])
    defer { if context.isLoaded { try? manager.controller.unload(context) } }
    #expect(!context.hasAccessToPrivateData)
    let privatePage = privateWindow.store.selectedTab.pages[0]
    #expect(manager.window(for: privateWindow.store).isPrivate(for: context))
    #expect(manager.window(for: privateWindow.store).tabs(for: context).isEmpty)
    #expect(!manager.isAvailable(id, pageID: privatePage.id))
    #expect(privateWindow.store.extensionConfiguration(for: context) == nil)
    #expect(manager.webExtensionController(manager.controller, openWindowsFor: context).count == 1)
    let options = WKWebView(frame: .zero, configuration: try #require(context.webViewConfiguration))
    let optionsNavigation = ExtensionTestNavigation()
    options.navigationDelegate = optionsNavigation
    try await optionsNavigation.load(options, url: try #require(context.optionsPageURL))
    let privateTabQuery = "return (await browser.tabs.query({})).filter(tab => tab.incognito).length;"
    let regularPaneCount = regular.store.session.workspaces.flatMap(\.tabs).flatMap(\.pages).count
    let tabCountQuery = "return (await browser.tabs.query({})).length;"
    #expect(try await options.callAsyncJavaScript(privateTabQuery, arguments: [:], in: nil, contentWorld: .page) as? Int == 0)
    let visibleCount = try await options.callAsyncJavaScript(tabCountQuery, arguments: [:], in: nil, contentWorld: .page) as? Int
    #expect(visibleCount == regularPaneCount)
    let server = try await ExtensionHTTPFixture.start()
    defer { server.listener.cancel() }
    let url = URL(string: "http://127.0.0.1:\(server.port)/")!
    let regularWeb = regular.store.controller(for: regular.store.selectedTab.pages[0]).webView
    let privateController = privateWindow.store.controller(for: privatePage)
    var privateWeb = privateController.webView
    #expect(regularWeb.configuration.userContentController !== privateWeb.configuration.userContentController)
    let navigation = ExtensionTestNavigation()
    regularWeb.navigationDelegate = navigation
    privateWeb.navigationDelegate = navigation
    try await navigation.load(regularWeb, url: url)
    #expect(try await regularWeb.evaluateJavaScript("document.body.dataset.browseExtension") as? String == "active")
    try await navigation.load(privateWeb, url: url)
    #expect(try await privateWeb.evaluateJavaScript("document.body.dataset.browseExtension || ''") as? String == "")
    #expect(try await privateWeb.evaluateJavaScript("window.blockedScriptRan === true") as? Bool == true)
    manager.setPrivateAccess(true, id: id)
    #expect(context.hasAccessToPrivateData)
    let privateCount = try await options.callAsyncJavaScript(privateTabQuery, arguments: [:], in: nil, contentWorld: .page) as? Int
    #expect(privateCount == 1)
    #expect(manager.isAvailable(id, pageID: privatePage.id))
    #expect(manager.webExtensionController(manager.controller, openWindowsFor: context).count == 2)
    #expect(manager.window(for: privateWindow.store).tabs(for: context).count == 1)
    try await navigation.load(privateWeb, url: url)
    #expect(try await privateWeb.evaluateJavaScript("document.body.dataset.browseExtension") as? String == "active")
    #expect(try await privateWeb.evaluateJavaScript("window.blockedScriptRan === true") as? Bool == false)
    // A host restart preserves the explicit opt-in; old records default to off.
    let saved = ExtensionManager(root: manager.root, persistent: false)
    #expect(saved.records.first?.enabledInPrivateMode == true)
    saved.start()
    await saved.restorationTask?.value
    let restoredContext = try #require(saved.contexts[id])
    #expect(restoredContext.hasAccessToPrivateData)
    // controller.load() returns before WebKit finishes loading its rule stores.
    // Exercise the restored host before unloading it: immediate teardown races
    // a WebKit DNR database callback on macOS 26 and can crash the test process.
    let restoredOptions = WKWebView(frame: .zero, configuration: try #require(restoredContext.webViewConfiguration))
    let restoredNavigation = ExtensionTestNavigation()
    restoredOptions.navigationDelegate = restoredNavigation
    try await restoredNavigation.load(restoredOptions, url: try #require(restoredContext.optionsPageURL))
    _ = try await restoredOptions.callAsyncJavaScript("""
        await browser.declarativeNetRequest.updateEnabledRulesets({disableRulesetIds: ['rules']});
        await browser.declarativeNetRequest.updateEnabledRulesets({enableRulesetIds: ['rules']});
        """, arguments: [:], in: nil, contentWorld: .page)
    let restoredConfiguration = WKWebViewConfiguration()
    saved.configure(restoredConfiguration)
    let restoredWeb = WKWebView(frame: .zero, configuration: restoredConfiguration)
    restoredWeb.navigationDelegate = restoredNavigation
    try await restoredNavigation.load(restoredWeb, url: url)
    #expect(try await restoredWeb.evaluateJavaScript("document.body.dataset.browseExtension") as? String == "active")
    #expect(try await restoredWeb.evaluateJavaScript("window.blockedScriptRan === true") as? Bool == false)
    if restoredContext.isLoaded { try saved.controller.unload(restoredContext) }
    #expect(privateWindow.store.extensionConfiguration(for: context) == nil)
    manager.setPrivateAccess(false, id: id)
    privateWeb = privateController.webView
    #expect(privateWeb.configuration.websiteDataStore === privateWindow.store.websiteDataStore(for: privatePage.id))
    #expect(!privateWeb.configuration.websiteDataStore.isPersistent)
    privateWeb.navigationDelegate = navigation
    #expect(!context.hasAccessToPrivateData)
    let revokedCount = try await options.callAsyncJavaScript(tabCountQuery, arguments: [:], in: nil, contentWorld: .page) as? Int
    #expect(revokedCount == regularPaneCount)
    #expect(manager.tabs[privatePage.id]?.webView(for: context) == nil)
    #expect(ExtensionManager(root: manager.root, persistent: false).records.first?.enabledInPrivateMode == false)
    try await navigation.load(privateWeb, url: url)
    #expect(try await privateWeb.evaluateJavaScript("document.body.dataset.browseExtension || ''") as? String == "")
    #expect(try await privateWeb.evaluateJavaScript("window.blockedScriptRan === true") as? Bool == true)
}

// @lat: [[tests#Private extension iframe isolation]]
@Test @MainActor func privateExtensionIframeIsolation() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("PrivateReview-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let persistentData = WKWebsiteDataStore(forIdentifier: UUID())
    let manager = ExtensionManager(root: root.appendingPathComponent("extensions"), persistent: false, websiteDataStore: persistentData)
    let regular = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false, extensionManager: manager)
    await manager.restorationTask?.value
    let privateStore = BrowserStore(sessionFile: root.appendingPathComponent("private.json"), sharedStore: regular, isPrivate: true)
    let normalWindow = NSWindow(), privateWindow = NSWindow()
    manager.attachWindow(normalWindow, store: regular)
    manager.attachWindow(privateWindow, store: privateStore)
    defer {
        manager.detachWindow(privateWindow); privateStore.stopWindow()
        manager.detachWindow(normalWindow); regular.stopWindow()
        Task { await persistentData.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) }
    }
    try await manager.importExtension(from: extensionFixture(at: root))
    let id = try #require(manager.records.first?.id)
    try await manager.enable(true, id: id) { _, _ in true }
    manager.setPrivateAccess(true, id: id)
    let context = try #require(manager.contexts[id])
    defer { try? manager.controller.unload(context) }
    let cookie = try #require(HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/", .name: "regularSecret", .value: "regular-session"]))
    await persistentData.httpCookieStore.setCookie(cookie)
    let listener = try NWListener(using: .tcp, on: .any)
    listener.newConnectionHandler = { connection in
        connection.start(queue: .global())
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { _, _, _, _ in
            let body = "<script>const before=document.cookie;document.cookie='privateSecret=private-session; path=/; max-age=3600';parent.postMessage(before, '*');</script>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: listener.stateUpdateHandler = nil; continuation.resume()
            case .failed(let error): listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
            default: break
            }
        }
        listener.start(queue: .global())
    }
    defer { listener.cancel() }

    let optionsURL = try #require(context.optionsPageURL)
    let sharedConfiguration = try #require(context.webViewConfiguration)
    let navigation = ExtensionTestNavigation()
    func probeIframe(_ web: WKWebView) async throws -> String? {
        web.navigationDelegate = navigation
        try await navigation.load(web, url: optionsURL)
        return try await web.callAsyncJavaScript("""
        return await new Promise(resolve => {
          const frame = document.createElement('iframe');
          frame.src = url;
          window.addEventListener('message', event => { frame.remove(); resolve(event.data); }, {once:true});
          document.body.append(frame);
          setTimeout(() => resolve('timeout'), 3000);
        });
        """, arguments: ["url": "http://127.0.0.1:\(listener.port!.rawValue)/"], in: nil, contentWorld: .page) as? String
    }
    // Positive control: this exact extension iframe can read and write the
    // isolated regular store. Never use the user's actual profile in this test.
    let options = WKWebView(frame: .zero, configuration: sharedConfiguration)
    #expect(try await probeIframe(options) == "regularSecret=regular-session")
    let controlCookies = await persistentData.httpCookieStore.allCookies()
    #expect(controlCookies.contains { $0.name == "privateSecret" })
    for cookie in controlCookies where cookie.name == "privateSecret" {
        await withCheckedContinuation { continuation in
            persistentData.httpCookieStore.delete(cookie) { continuation.resume() }
        }
    }
    options.stopLoading()

    let privatePage = privateStore.selectedTab.pages[0]
    let page = privateStore.controller(for: privatePage)
    let originalView = page.webView
    // Exercise the original leak if a future change supplies a configuration.
    let configuration = privateStore.extensionConfiguration(for: context)
    #expect(configuration == nil)
    if let configuration {
        page.navigateExtension(optionsURL, configuration: configuration)
        #expect(try await probeIframe(page.webView) == "")
    }
    // The controller also refuses a shared configuration supplied directly.
    page.navigateExtension(optionsURL, configuration: sharedConfiguration)
    #expect(page.webView === originalView)
    #expect(page.isStartPage)
    #expect(page.error != nil)
    #expect(!page.webView.configuration.websiteDataStore.isPersistent)

    let tab = try #require(manager.tabs[privatePage.id])
    let loadError: Error? = await withCheckedContinuation { continuation in
        tab.loadURL(optionsURL, for: context) { continuation.resume(returning: $0) }
    }
    #expect(loadError != nil)
    // Both host actions and extension-initiated popups reject before asking
    // WebKit for a popup view backed by shared website storage.
    page.error = nil
    manager.performAction(id, pageID: privatePage.id)
    #expect(page.error?.contains("popups are unavailable") == true)
    let action = try #require(context.action(for: tab))
    let popupError: Error? = await withCheckedContinuation { continuation in
        manager.webExtensionController(manager.controller, presentActionPopup: action, for: context) {
            continuation.resume(returning: $0)
        }
    }
    #expect(popupError?.localizedDescription.contains("popups are unavailable") == true)
    #expect(manager.popup == nil)
    // Creating an extension tab must reject before adding a private pane.
    let privateTabQuery = "(await browser.tabs.query({incognito: true}))[0]"
    let privateID = try await options.callAsyncJavaScript("return (" + privateTabQuery + ").windowId", arguments: [:], in: nil, contentWorld: .page)
    let count = privateStore.session.workspaces.flatMap(\.tabs).count
    #expect(try await options.callAsyncJavaScript("""
        try { await browser.tabs.create({windowId, url}); return false; }
        catch { return true; }
        """, arguments: ["windowId": try #require(privateID), "url": optionsURL.absoluteString], in: nil, contentWorld: .page) as? Bool == true)
    #expect(privateStore.session.workspaces.flatMap(\.tabs).count == count)

    // Lazy controller creation must not load an extension-origin page either.
    privateStore.newTab(address: optionsURL.absoluteString)
    let restored = privateStore.controller(for: privateStore.selectedTab.pages[0])
    for _ in 0..<50 {
        if restored.error != nil { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(restored.isStartPage)
    #expect(restored.error != nil)
    #expect(!restored.webView.configuration.websiteDataStore.isPersistent)
    let cookies = await persistentData.httpCookieStore.allCookies()
    #expect(!cookies.contains { $0.name == "privateSecret" })
    privateStore.stopWindow()
    let afterClose = await persistentData.httpCookieStore.allCookies()
    #expect(!afterClose.contains { $0.name == "privateSecret" })
    #expect(afterClose.contains { $0.name == "regularSecret" && $0.value == "regular-session" })
}
