import AppKit
import Testing
import UserNotifications
import WebKit
import Network
@testable import Browse

@MainActor final class TestNotifications: ExtensionNotificationDelivering {
    var onResponse: ((String, String) -> Void)?
    var delivered: [String: String] = [:]
    var allowed = true
    func permission() async -> Bool { allowed }
    func post(key: String, title: String, message: String, buttons: [String]) async throws {
        if !allowed { throw NSError(domain: "test", code: 1) }
        delivered[key] = message
    }
    func remove(keys: [String]) { for key in keys { delivered[key] = nil } }
    func keys() async -> Set<String> { Set(delivered.keys) }
}

@MainActor private final class CompatibilityNavigation: NSObject, WKNavigationDelegate {
    var done: CheckedContinuation<Void, Error>?
    var timeout: Task<Void, Never>?
    func begin(_ continuation: CheckedContinuation<Void, Error>) {
        done = continuation
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            self?.finish(NSError(domain: "Browse.Tests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Navigation timed out"]))
        }
    }
    func finish(_ error: Error? = nil) {
        timeout?.cancel(); timeout = nil
        if let error { done?.resume(throwing: error) } else { done?.resume() }
        done = nil
    }
    func load(_ web: WKWebView, _ url: URL) async throws {
        try await withCheckedThrowingContinuation { begin($0); web.load(URLRequest(url: url)) }
    }
    func loadHTML(_ web: WKWebView, _ html: String, baseURL: URL) async throws {
        try await withCheckedThrowingContinuation { begin($0); web.loadHTMLString(html, baseURL: baseURL) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(error) }
}

@MainActor private func compatibilityFixture(_ root: URL, notifications: Bool = true) throws -> URL {
    let source = root.appendingPathComponent("fixture")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let permissions = notifications ? #"["notifications","tabs","webNavigation","http://example.test/*"]"# : #"["tabs","webNavigation","http://example.test/*"]"#
    try Data("""
        {"manifest_version":2,"name":"Compatibility fixture","description":"Browse compatibility tests","version":"1.0",
        "permissions":\(permissions),"background":{"scripts":["background.js"],"persistent":true},
        "browser_action":{"default_title":"Fixture"},"options_ui":{"page":"options.html"}}
        """.utf8).write(to: source.appendingPathComponent("manifest.json"))
    try Data(#"""
        browser.runtime.onMessage.addListener((message, sender, reply) => { reply({echo: message}); });
        browser.browserAction.onClicked.addListener(() => browser.storage?.local?.set({clicked: true}));
        """#.utf8).write(to: source.appendingPathComponent("background.js"))
    try Data("<body>Compatibility test</body>".utf8).write(to: source.appendingPathComponent("options.html"))
    return source
}

// @lat: [[tests#Extension compatibility permissions and notifications]]
@Test @MainActor func extensionCompatibilityNotifications() async throws {
    guard #available(macOS 15.4, *) else { return }
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseCompatibility-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let backend = TestNotifications()
    let manager = ExtensionManager(root: root.appendingPathComponent("installed"), persistent: false,
        websiteDataStore: .nonPersistent(), notifications: backend)
    manager.presentsWindows = false
    try await manager.importExtension(from: compatibilityFixture(root))
    let id = try #require(manager.records.first?.id)
    try await manager.enable(true, id: id) { _, _ in true }
    let context = try #require(manager.contexts[id])
    try await context.loadBackgroundContent()
    let web = WKWebView(frame: .zero, configuration: try #require(context.webViewConfiguration))
    let navigation = CompatibilityNavigation(); web.navigationDelegate = navigation
    try await navigation.load(web, try #require(context.optionsPageURL))
    let result = try await web.callAsyncJavaScript(#"""
        const reply = await browser.runtime.sendMessage('hello');
        globalThis.closed = [];
        globalThis.clicked = [];
        chrome.notifications.onClosed.addListener((...args) => closed.push(args));
        chrome.notifications.onClicked.addListener(id => clicked.push(id));
        await chrome.notifications.create('same-id', {type:'basic', title:'Saved', message:'Test only'});
        const all = await chrome.notifications.getAll();
        return JSON.stringify({reply, all});
        """#, arguments: [:], in: nil, contentWorld: .page) as? String
    #expect(result?.contains("hello") == true)
    #expect(result?.contains("same-id") == true)
    #expect(backend.delivered.count == 1)
    let originalKey = try #require(backend.delivered.keys.first)
    let other = UUID()
    _ = try await manager.compatibility.notificationOperation("create", id: other, name: "Other", body: [
        "id": "same-id", "options": ["type": "basic", "title": "Other", "message": "Isolated"]])
    #expect(backend.delivered.count == 2)
    _ = try await manager.compatibility.notificationOperation("clear", id: other, name: "Other", body: ["id": "same-id"])
    #expect(backend.delivered[originalKey] == "Test only")
    backend.onResponse?(originalKey, UNNotificationDefaultActionIdentifier)
    try await Task.sleep(for: .milliseconds(100))
    #expect(try await web.evaluateJavaScript("clicked[0]") as? String == "same-id")
    #expect(try await web.callAsyncJavaScript("return await chrome.notifications.clear('same-id')", arguments: [:], in: nil, contentWorld: .page) as? Bool == true)
    #expect(backend.delivered.isEmpty)
    context.setPermissionStatus(.deniedExplicitly, for: .init(rawValue: "notifications"))
    let denied = try await web.callAsyncJavaScript(#"""
        try { await chrome.notifications.create('denied', {type:'basic', title:'x', message:'x'}); return false; }
        catch { return true; }
        """#, arguments: [:], in: nil, contentWorld: .page)
    #expect(denied as? Bool == true)
    let callbackError = try await web.callAsyncJavaScript(#"""
        return await new Promise(resolve => chrome.notifications.create('denied', {type:'basic', title:'x', message:'x'}, () => resolve(chrome.runtime.lastError?.message || '')));
        """#, arguments: [:], in: nil, contentWorld: .page) as? String
    #expect(callbackError?.contains("permission") == true)
    #expect(try await web.evaluateJavaScript("chrome.runtime.lastError == null") as? Bool == true)
    #expect(backend.delivered.isEmpty)
    context.setPermissionStatus(.grantedExplicitly, for: .init(rawValue: "notifications"))
    _ = try await web.callAsyncJavaScript("return await chrome.notifications.create('cleanup', {type:'basic', title:'x', message:'x'})", arguments: [:], in: nil, contentWorld: .page)
    #expect(backend.delivered.count == 1)
    _ = try await web.callAsyncJavaScript(#"""
        window.dispatchEvent(new ErrorEvent('error', {error: new TypeError('IndexedDB NEVER-LOG-JS-SECRET')}));
        await new Promise(resolve => setTimeout(resolve, 30));
        try { await window.webkit.messageHandlers.browseExtension.postMessage({operation:'diagnostic',kind:'error',category:'NEVER-LOG-JS-SECRET',errorName:'Error'}); return false; }
        catch { return true; }
        """#, arguments: [:], in: nil, contentWorld: .page)
    let diagnostic = manager.diagnosticReport()
    #expect(diagnostic.contains("javascriptError"))
    #expect(diagnostic.contains("indexeddb"))
    #expect(!diagnostic.contains("NEVER-LOG-JS-SECRET"))
    // Even a website with the message handler installed must not gain bridge authority.
    let untrustedConfiguration = WKWebViewConfiguration()
    untrustedConfiguration.websiteDataStore = .nonPersistent()
    manager.compatibility.configure(untrustedConfiguration)
    let untrusted = WKWebView(frame: .zero, configuration: untrustedConfiguration)
    untrusted.navigationDelegate = navigation
    try await navigation.loadHTML(untrusted, "<body>Untrusted page</body>", baseURL: URL(string: "https://example.test/")!)
    let rejected = try await untrusted.callAsyncJavaScript(#"""
        try { await window.webkit.messageHandlers.browseExtension.postMessage({operation:'getAll'}); return false; }
        catch { return true; }
        """#, arguments: [:], in: nil, contentWorld: .page)
    #expect(rejected as? Bool == true)
    try await manager.enable(false, id: id) { _, _ in true }
    #expect(backend.delivered.isEmpty)
}

// @lat: [[tests#Extension created navigation events]]
@Test @MainActor func extensionCreatedNavigationEvents() async throws {
    guard #available(macOS 15.4, *) else { return }
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseNavigationAPI-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = ExtensionManager(root: root.appendingPathComponent("installed"), persistent: false, websiteDataStore: .nonPersistent(), notifications: TestNotifications())
    manager.presentsWindows = false
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), extensionManager: manager)
    try await manager.importExtension(from: compatibilityFixture(root, notifications: false))
    let id = try #require(manager.records.first?.id)
    try await manager.enable(true, id: id) { _, _ in true }
    let context = try #require(manager.contexts[id])
    let web = WKWebView(frame: .zero, configuration: try #require(context.webViewConfiguration))
    let navigation = CompatibilityNavigation(); web.navigationDelegate = navigation
    try await navigation.load(web, try #require(context.optionsPageURL))
    _ = try await web.evaluateJavaScript(#"""
        globalThis.created = []; globalThis.nativeTabs = [];
        chrome.webNavigation.onCreatedNavigationTarget.addListener(event => created.push(event), {url:[{hostEquals:'example.test'}]});
        browser.tabs.onCreated.addListener(tab => nativeTabs.push(tab.id));
        """#)
    let source = store.selectedTab.focusedPane
    store.openPane(address: "http://example.test/new", toRightOf: source)
    manager.synchronizeTabs()
    try await Task.sleep(for: .milliseconds(200))
    #expect(try await web.evaluateJavaScript("created.length") as? Int == 1)
    #expect(try await web.evaluateJavaScript("created[0].sourceFrameId") as? Int == 0)
    #expect(try await web.evaluateJavaScript("created[0].tabId === nativeTabs[0]") as? Bool == true)
    store.newTab(address: "http://example.test/unrelated")
    manager.synchronizeTabs()
    store.openPane(address: "http://example.test/subframe", toRightOf: source, fromMainFrame: false)
    manager.synchronizeTabs()
    try await Task.sleep(for: .milliseconds(150))
    #expect(try await web.evaluateJavaScript("created.length") as? Int == 1)
    try await manager.enable(false, id: id) { _, _ in true }
}

// @lat: [[tests#Embedded extension pages and tab transitions]]
@Test @MainActor func extensionEmbeddedPagesAndTabTransitions() async throws {
    guard #available(macOS 15.4, *) else { return }
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseExtensionFrames-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try compatibilityFixture(root, notifications: false)
    let manifestURL = source.appendingPathComponent("manifest.json")
    var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
    manifest["permissions"] = ["tabs", "webNavigation", "http://127.0.0.1/*"]
    manifest["web_accessible_resources"] = ["embedded.html", "embedded.js"]
    try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
    try Data("<body>Inline menu<script src='embedded.js'></script></body>".utf8).write(to: source.appendingPathComponent("embedded.html"))
    try Data(#"browser.runtime.sendMessage('embedded').then(reply => parent.postMessage({fixture: reply.echo}, '*'));"#.utf8).write(to: source.appendingPathComponent("embedded.js"))
    try Data("<body>Private<script src='private.js'></script></body>".utf8).write(to: source.appendingPathComponent("private.html"))
    try Data("parent.postMessage({fixture: 'private-leak'}, '*');".utf8).write(to: source.appendingPathComponent("private.js"))
    let manager = ExtensionManager(root: root.appendingPathComponent("installed"), persistent: false,
        websiteDataStore: .nonPersistent(), notifications: TestNotifications())
    manager.presentsWindows = false
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), extensionManager: manager)
    try await manager.importExtension(from: source)
    let id = try #require(manager.records.first?.id)
    try await manager.enable(true, id: id) { _, _ in true }
    let context = try #require(manager.contexts[id])
    try await context.loadBackgroundContent()
    let server = try await ExtensionHTTPFixture.start()
    defer { server.listener.cancel() }
    let address = "http://127.0.0.1:\(server.port)/"
    let page = store.selectedTab.pages[0]
    let controller = store.controller(for: page)
    controller.webView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
    controller.navigate(address)
    for _ in 0..<50 {
        if (try? await controller.webView.evaluateJavaScript("document.body?.textContent.includes('Fixture')")) as? Bool == true { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    let loaded = try await controller.webView.callAsyncJavaScript(#"""
        globalThis.privateLeak = false;
        window.addEventListener('message', event => { if (event.data?.fixture === 'private-leak') privateLeak = true; });
        const privateFrame = document.createElement('iframe'); privateFrame.src = base + 'private.html'; document.body.append(privateFrame);
        return await new Promise(resolve => {
            const frame = document.createElement('iframe');
            const timeout = setTimeout(() => resolve(false), 2500);
            window.addEventListener('message', event => {
                if (event.source === frame.contentWindow && event.data?.fixture === 'embedded') { clearTimeout(timeout); resolve(true); }
            });
            frame.src = base + 'embedded.html'; document.body.append(frame);
        });
        """#, arguments: ["base": context.baseURL.absoluteString], in: nil, contentWorld: .page)
    #expect(loaded as? Bool == true)
    #expect(try await controller.webView.evaluateJavaScript("privateLeak") as? Bool == false)
    // A website cannot promote itself into a privileged extension document.
    controller.webView.load(URLRequest(url: context.baseURL.appendingPathComponent("options.html")))
    try await Task.sleep(for: .milliseconds(100))
    #expect(controller.webView.url?.absoluteString == address)

    // Match the post-authentication operation: tabs.update(webTabID, extensionURL).
    let document = try manager.openDocument(url: try #require(context.optionsPageURL), context: context, active: false)
    for _ in 0..<50 {
        if (try? await document.web.evaluateJavaScript("document.body?.textContent")) as? String == "Compatibility test" { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    let transition = try await document.web.callAsyncJavaScript(#"""
        const before = (await browser.tabs.query({})).find(tab => tab.url === address);
        const after = await browser.tabs.update(before.id, {url: browser.runtime.getURL('/options.html#ready')});
        return {before: before.id, after: after.id};
        """#, arguments: ["address": address], in: nil, contentWorld: .page) as? [String: Any]
    #expect(transition?["before"] as? Int == transition?["after"] as? Int)
    for _ in 0..<50 {
        if (try? await controller.webView.evaluateJavaScript("document.body?.textContent")) as? String == "Compatibility test" { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    #expect(controller.webView.url?.fragment == "ready")
    #expect(try await controller.webView.evaluateJavaScript("browser.runtime.id") as? String == context.uniqueIdentifier)
    #expect(manager.tabs[page.id]?.pageController === controller)
    store.save()
    let restoredManager = ExtensionManager(root: root.appendingPathComponent("installed"), persistent: false,
        websiteDataStore: .nonPersistent(), notifications: TestNotifications())
    restoredManager.presentsWindows = false
    let restoredStore = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), extensionManager: restoredManager)
    let restoredController = restoredStore.controller(for: restoredStore.selectedTab.pages[0])
    for _ in 0..<50 {
        if (try? await restoredController.webView.evaluateJavaScript("document.body?.textContent")) as? String == "Compatibility test" { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    #expect(restoredController.webView.url?.fragment == "ready")
    #expect(try await restoredController.webView.evaluateJavaScript("browser.runtime.id") as? String == context.uniqueIdentifier)
    try await restoredManager.enable(false, id: id) { _, _ in true }
    #expect(restoredController.isStartPage)
    #expect(restoredController.error?.contains("unavailable") == true)

    _ = try await controller.webView.callAsyncJavaScript("location.href = address", arguments: ["address": address], in: nil, contentWorld: .page)
    for _ in 0..<50 {
        if (try? await controller.webView.evaluateJavaScript("document.body?.textContent.includes('Fixture')")) as? Bool == true { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    #expect(controller.webView.url?.absoluteString == address)
    // WebKit exposes runtime for externally_connectable websites, but no extension identity or privileged APIs.
    #expect(try await controller.webView.evaluateJavaScript("browser.runtime.id === undefined && browser.tabs === undefined && typeof chrome === 'undefined'") as? Bool == true)
    try await manager.enable(false, id: id) { _, _ in true }
}

// @lat: [[tests#Extension privacy settings and restored startup]]
@Test @MainActor func extensionPrivacyRestoration() async throws {
    guard #available(macOS 15.4, *) else { return }
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowsePrivacy-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try compatibilityFixture(root)
    let manifestURL = source.appendingPathComponent("manifest.json")
    var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
    manifest["permissions"] = ["privacy", "storage", "tabs"]
    try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
    try Data(#"""
        (async () => {
            if ((await browser.storage.local.get('configured')).configured) {
                await chrome.privacy.services.passwordSavingEnabled.set({value: false});
                await chrome.privacy.services.autofillEnabled.clear({});
            }
            browser.runtime.onMessage.addListener((message, sender, reply) => { reply('ready'); });
        })().catch(error => console.error(String(error)));
        """#.utf8).write(to: source.appendingPathComponent("background.js"))
    let storageID = UUID()
    let installed = root.appendingPathComponent("installed")
    var manager = ExtensionManager(root: installed, storageIdentifier: storageID, websiteDataStore: .nonPersistent(), notifications: TestNotifications())
    try await manager.importExtension(from: source)
    let id = try #require(manager.records.first?.id)
    try await manager.enable(true, id: id) { _, permissions in
        #expect(permissions.contains("privacy")); return false
    }
    #expect(!manager.isEnabled(id))
    try await manager.enable(true, id: id) { _, _ in true }
    for launch in 0..<3 {
        let context = try #require(manager.contexts[id])
        #expect(manager.isEnabled(id))
        #expect(manager.records.first?.permissions.contains("privacy") == true)
        try await context.loadBackgroundContent()
        let web = WKWebView(frame: .zero, configuration: try #require(context.webViewConfiguration))
        let navigation = CompatibilityNavigation(); web.navigationDelegate = navigation
        try await navigation.load(web, try #require(context.optionsPageURL))
        let result = try await web.callAsyncJavaScript(#"""
            const ready = await Promise.race([
                browser.runtime.sendMessage('ready'),
                new Promise(resolve => setTimeout(() => resolve('timeout'), 2000))
            ]);
            const values = [];
            for (const setting of Object.values(chrome.privacy.services)) {
                values.push(await new Promise(resolve => setting.get({}, resolve)));
                await setting.set({value: false});
                await new Promise(resolve => setting.clear({}, resolve));
            }
            let refused = false;
            try { await browser.privacy.services.passwordSavingEnabled.set({value:true}); }
            catch { refused = true; }
            await browser.storage.local.set({configured: true});
            return ready === 'ready' && refused && values.length === 4 && values.every(v => v.value === false && v.levelOfControl === 'not_controllable');
            """#, arguments: [:], in: nil, contentWorld: .page)
        #expect(result as? Bool == true)
        #expect(context.errors.isEmpty, "\(context.errors.map(\.localizedDescription))")
        context.setPermissionStatus(.deniedExplicitly, for: .init(rawValue: "privacy"))
        #expect(try await web.callAsyncJavaScript(#"""
            return await new Promise(resolve => chrome.privacy.services.passwordSavingEnabled.get({}, () => resolve(!!chrome.runtime.lastError)));
            """#, arguments: [:], in: nil, contentWorld: .page) as? Bool == true)
        #expect(try await web.evaluateJavaScript("chrome.runtime.lastError == null") as? Bool == true)
        try manager.controller.unload(context)
        if launch < 2 {
            manager = ExtensionManager(root: installed, storageIdentifier: storageID, websiteDataStore: .nonPersistent(), notifications: TestNotifications())
            manager.start(); await manager.restorationTask?.value
        }
    }
    try await manager.uninstall(id)
}

// @lat: [[tests#Extension document authentication round trip]]
@Test @MainActor func extensionDocumentAuthenticationRoundTrip() async throws {
    guard #available(macOS 15.4, *) else { return }
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseAuthRoundTrip-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = ExtensionManager(root: root.appendingPathComponent("installed"), persistent: false,
        websiteDataStore: .nonPersistent(), notifications: TestNotifications())
    manager.presentsWindows = false
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), extensionManager: manager)
    try await manager.importExtension(from: compatibilityFixture(root))
    let id = try #require(manager.records.first?.id)
    try await manager.enable(true, id: id) { _, _ in true }
    let context = try #require(manager.contexts[id])
    let url = try #require(context.optionsPageURL)
    let control = WKWebView(frame: .zero, configuration: try #require(context.webViewConfiguration))
    let navigation = CompatibilityNavigation(); control.navigationDelegate = navigation
    try await navigation.load(control, url)
    let document = try manager.openDocument(url: url, context: context)
    for _ in 0..<100 {
        if (try? await document.web.evaluateJavaScript("document.body?.textContent")) as? String == "Compatibility test" { break }
        try await Task.sleep(for: .milliseconds(30))
    }
    let tabID = try #require(try await document.web.callAsyncJavaScript("sessionStorage.setItem('setupAnswered', 'yes'); return (await browser.tabs.getCurrent()).id", arguments: [:], in: nil, contentWorld: .page) as? Int)
    let pageCount = store.session.workspaces.flatMap(\.tabs).flatMap(\.pages).count
    let server = try await ExtensionHTTPFixture.start()
    defer { server.listener.cancel() }
    let address = "http://127.0.0.1:\(server.port)/"
    // Navigation is synchronous JavaScript. Do not await an injected async
    // function's promise across a document/view transition: WebKit can collect
    // its completion handler even though the navigation succeeds.
    let websiteLiteral = String(decoding: try JSONEncoder().encode(address), as: UTF8.self)
    _ = try await document.web.evaluateJavaScript("location.href = \(websiteLiteral)")
    for _ in 0..<100 {
        if document.web.url?.host == "127.0.0.1", !document.web.isLoading { break }
        try await Task.sleep(for: .milliseconds(30))
    }
    #expect(document.web.url?.host == "127.0.0.1")
    #expect(manager.pages.count == pageCount)
    #expect(try await document.web.evaluateJavaScript("sessionStorage.getItem('setupAnswered') === null && !globalThis.browser?.runtime?.id && typeof chrome === 'undefined'") as? Bool == true)
    #expect(try await document.web.callAsyncJavaScript("try { await webkit.messageHandlers.browseExtension.postMessage({operation:'privacySetting', setting:'passwordSavingEnabled', action:'get', details:{}}); return false; } catch { return true; }", arguments: [:], in: nil, contentWorld: .page) as? Bool == true)
    // A website cannot authorize its own promotion into an extension document.
    let extensionLiteral = String(decoding: try JSONEncoder().encode(url.absoluteString), as: UTF8.self)
    _ = try await document.web.evaluateJavaScript("location.href = \(extensionLiteral)")
    try await Task.sleep(for: .milliseconds(150))
    #expect(document.web.url?.host == "127.0.0.1")
    _ = try await control.callAsyncJavaScript("return await browser.tabs.update(tabID, {url: address})", arguments: ["tabID": tabID, "address": url.absoluteString], in: nil, contentWorld: .page)
    for _ in 0..<100 {
        if (try? await document.web.evaluateJavaScript("sessionStorage.getItem('setupAnswered')")) as? String == "yes" { break }
        try await Task.sleep(for: .milliseconds(30))
    }
    #expect(try await document.web.evaluateJavaScript("sessionStorage.getItem('setupAnswered')") as? String == "yes")
    #expect(try await document.web.callAsyncJavaScript("return (await browser.tabs.getCurrent()).id", arguments: [:], in: nil, contentWorld: .page) as? Int == tabID)
    try await manager.enable(false, id: id) { _, _ in true }
}

// @lat: [[tests#Firefox onboarding smoke test]]
@Test @MainActor func firefoxOnboardingSmoke() async throws {
    guard #available(macOS 15.4, *), let path = ProcessInfo.processInfo.environment["BROWSE_TEST_FIREFOX_PACKAGE"] else { return }
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseFirefoxSmoke-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = ExtensionManager(root: root.appendingPathComponent("installed"), persistent: false,
        websiteDataStore: .nonPersistent(), notifications: TestNotifications())
    manager.presentsWindows = false
    var nativeAttempts = Set<String>()
    manager.nativeMessaging.resolve = { name, id in
        #expect(["com.1password.1password", "com.1password.1password7"].contains(name))
        #expect(id == "{d634138d-c276-4fc8-924b-40a0ea21d284}")
        nativeAttempts.insert(name)
        return NativeHost(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [])
    }
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), extensionManager: manager)
    try await manager.importExtension(from: URL(fileURLWithPath: path))
    let id = try #require(manager.records.first?.id)
    try await manager.enable(true, id: id) { _, _ in true }
    let context = try #require(manager.contexts[id])
    try await context.loadBackgroundContent()
    try await Task.sleep(for: .seconds(25))
    #expect(nativeAttempts.contains("com.1password.1password"))
    manager.performAction(id, pageID: store.selectedTab.focusedPane)
    for _ in 0..<50 where manager.documents.isEmpty { try await Task.sleep(for: .milliseconds(200)) }
    let document = try #require(manager.documents.values.first)
    try await Task.sleep(for: .seconds(3))
    let text = try await document.web.evaluateJavaScript("document.body.innerText") as? String
    print("FIREFOX_ONBOARDING", text ?? "nil")
    print("FIREFOX_ERRORS", context.errors.map(\.localizedDescription))
    #expect(text?.contains("Welcome to 1Password") == true)
    let declined = try await document.web.callAsyncJavaScript(#"""
        let count = 0;
        for (let index = 0; index < 3; index++) {
            const button = [...document.querySelectorAll('button')].find(button => button.textContent.trim() === "Don't enable");
            if (!button) break;
            button.click(); count++;
            await new Promise(resolve => setTimeout(resolve, 150));
        }
        return count;
        """#, arguments: [:], in: nil, contentWorld: .page)
    print("FIREFOX_CONSENT_CHOICES", declined ?? "nil")
    try await Task.sleep(for: .seconds(3))
    let next = try await document.web.evaluateJavaScript("document.body.innerText") as? String
    #expect(next?.contains("Sign in") == true)
    #expect(declined as? Int == 3)
    let onboardingURL = try #require(document.web.url)
    let extensionView = document.web
    #expect(try await extensionView.evaluateJavaScript("sessionStorage.getItem('firefoxPermissionsCompleted')") as? String == "true")
    let pageCount = manager.pages.count
    _ = try await extensionView.evaluateJavaScript("[...document.querySelectorAll('button')].find(button => button.textContent.trim() === 'Sign in').click()")
    var signinText = ""
    for _ in 0..<80 {
        signinText = (try? await document.web.evaluateJavaScript("document.body?.innerText || ''")) as? String ?? ""
        if document.web.url?.scheme == "https", signinText.localizedCaseInsensitiveContains("email") { break }
        try await Task.sleep(for: .milliseconds(250))
    }
    #expect(document.web !== extensionView)
    #expect(manager.pages.count == pageCount)
    #expect(document.web.url?.scheme == "https")
    #expect(signinText.localizedCaseInsensitiveContains("email"))
    #expect(try await document.web.evaluateJavaScript("!globalThis.browser?.runtime?.id && typeof chrome === 'undefined'") as? Bool == true)
    // Exercise the extension's return navigation without credentials or an account.
    document.loadURL(onboardingURL, for: context) { error in #expect(error == nil) }
    #expect(document.web === extensionView)
    var returnedText = ""
    for _ in 0..<80 {
        returnedText = (try? await document.web.evaluateJavaScript("document.body?.innerText || ''")) as? String ?? ""
        if returnedText.contains("Sign in") { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    #expect(try await document.web.evaluateJavaScript("sessionStorage.getItem('firefoxPermissionsCompleted')") as? String == "true")
    #expect(returnedText.contains("Sign in"))
    #expect(!returnedText.contains("Before you get started"))
    #expect(!returnedText.contains("Don't enable"))
    #expect(context.errors.isEmpty, "\(context.errors.map(\.localizedDescription))")
    try await manager.enable(false, id: id) { _, _ in true }
}

// @lat: [[tests#Extension WASM diagnostic behavior]]
@Test @MainActor func extensionWasmDiagnostics() async throws {
    guard #available(macOS 15.4, *) else { return }
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseWasmDiagnostics-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try compatibilityFixture(root)
    let manifestURL = source.appendingPathComponent("manifest.json")
    var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
    manifest["content_security_policy"] = "script-src 'self' 'wasm-unsafe-eval'; object-src 'self'"
    try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
    let module = Data([0,97,115,109,1,0,0,0])
    try module.write(to: source.appendingPathComponent("NEVER-LOG-MODULE-SECRET.wasm"))
    let manager = ExtensionManager(root: root.appendingPathComponent("installed"), persistent: false,
        websiteDataStore: .nonPersistent(), notifications: TestNotifications())
    manager.presentsWindows = false
    try await manager.importExtension(from: source)
    let id = try #require(manager.records.first?.id)
    try await manager.enable(true, id: id) { _, _ in true }
    let context = try #require(manager.contexts[id])
    defer { try? manager.controller.unload(context) }
    let web = WKWebView(frame: .zero, configuration: try #require(context.webViewConfiguration))
    let navigation = CompatibilityNavigation(); web.navigationDelegate = navigation
    try await navigation.load(web, try #require(context.optionsPageURL))
    let result = try await web.callAsyncJavaScript(#"""
        const response = await fetch('NEVER-LOG-MODULE-SECRET.wasm');
        const bytes = await response.arrayBuffer();
        // The observer must preserve MIME rejection and allow the caller's
        // normal ArrayBuffer fallback, without consuming the response body.
        let rejected = false;
        try { await WebAssembly.instantiateStreaming(new Response(bytes, {headers:{'Content-Type':'text/plain'}})); }
        catch (e) { rejected = e instanceof TypeError; }
        const compiled = await WebAssembly.instantiate(bytes);
        let invalid = false;
        try { await WebAssembly.compile(new Uint8Array([1,2,3])); }
        catch (e) { invalid = e instanceof WebAssembly.CompileError; }
        window.dispatchEvent(new ErrorEvent('error', {error: new WebAssembly.RuntimeError('NEVER-LOG-TRAP-SECRET')}));
        await new Promise(resolve => setTimeout(resolve, 100));
        return rejected && invalid && compiled.instance instanceof WebAssembly.Instance;
        """#, arguments: [:], in: nil, contentWorld: .page)
    #expect(result as? Bool == true)
    let report = manager.diagnosticReport()
    #expect(report.contains("wasmOperation"))
    #expect(report.contains("mime-type"))
    #expect(report.contains("CompileError"))
    #expect(report.contains("RuntimeError"))
    #expect(report.contains("\"stage\":\"succeeded\""))
    #expect(!report.contains("NEVER-LOG-MODULE-SECRET"))
    #expect(!report.contains("NEVER-LOG-TRAP-SECRET"))
    // Exercise observer failures and error identity independently of the engine.
    let script = #"""
        const originalFetch = globalThis.fetch, originalCompile = WebAssembly.compile;
        const sentinel = new Error('NEVER-LOG-ERROR-SECRET');
        const observations = [];
        const native = browser;
        let failLogging = false;
        const call = (_, fields) => { observations.push(fields); if (failLogging) throw sentinel; return Promise.resolve(); };
        try {
            WebAssembly.compile = () => Promise.reject(sentinel);
            __OBSERVER__
            let preserved = false, preservedWhenLoggingFails = false;
            try { await WebAssembly.compile(new Uint8Array()); } catch(e) { preserved = e === sentinel; }
            failLogging = true;
            try { await WebAssembly.compile(new Uint8Array()); } catch(e) { preservedWhenLoggingFails = e === sentinel; }
            return preserved && preservedWhenLoggingFails && !JSON.stringify(observations).includes('NEVER-LOG-ERROR-SECRET');
        } finally { globalThis.fetch = originalFetch; WebAssembly.compile = originalCompile; }
        """#.replacingOccurrences(of: "__OBSERVER__", with: ExtensionWasmDiagnostics.javascript)
    #expect(try await web.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page) as? Bool == true)
    let rejected = try await web.callAsyncJavaScript(#"""
        try { await window.webkit.messageHandlers.browseExtension.postMessage({operation:'wasmDiagnostic',phase:'SECRET'}); return false; }
        catch { return true; }
        """#, arguments: [:], in: nil, contentWorld: .page)
    #expect(rejected as? Bool == true)
}

// @lat: [[tests#Native extension messaging]]
@Test @MainActor func nativeExtensionMessaging() async throws {
    guard #available(macOS 15.4, *) else { return }
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseNative-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try compatibilityFixture(root)
    let manifestURL = source.appendingPathComponent("manifest.json")
    var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
    manifest["permissions"] = ["nativeMessaging"]
    manifest["browser_specific_settings"] = ["gecko": ["id": "native@test"]]
    try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
    let script = root.appendingPathComponent("host.py")
    try Data(#"""
    import sys, struct, json
    while True:
        header = sys.stdin.buffer.read(4)
        if len(header) != 4: break
        length = struct.unpack('<I', header)[0]
        data = sys.stdin.buffer.read(length)
        message = json.loads(data)
        if message == 'crash': sys.exit(1)
        if message == 'malformed':
            sys.stdout.buffer.write(struct.pack('<I', 0xffffffff)); sys.stdout.buffer.flush(); continue
        response = json.dumps({'echo': message}).encode()
        frame = struct.pack('<I',len(response)) + response
        for byte in frame:
            sys.stdout.buffer.write(bytes([byte])); sys.stdout.buffer.flush()
    """#.utf8).write(to: script)
    let host = NativeHost(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", script.path])
    for _ in 0..<2 {
        let manager = ExtensionManager(root: root.appendingPathComponent("installed"), persistent: false,
            websiteDataStore: .nonPersistent(), notifications: TestNotifications())
        manager.presentsWindows = false
        manager.nativeMessaging.resolve = { name, id in
            #expect(name == "test.host"); #expect(id == "native@test")
            return host
        }
        if manager.records.isEmpty {
            try await manager.importExtension(from: source)
            try await manager.enable(true, id: try #require(manager.records.first?.id)) { _, _ in true }
        } else { manager.start(); await manager.restorationTask?.value }
        let id = try #require(manager.records.first?.id), context = try #require(manager.contexts[id])
        let web = WKWebView(frame: .zero, configuration: try #require(context.webViewConfiguration))
        let navigation = CompatibilityNavigation(); web.navigationDelegate = navigation
        try await navigation.load(web, try #require(context.optionsPageURL))
        let reply = try await web.callAsyncJavaScript(#"""
            const timeout = new Promise((_, reject) => setTimeout(() => reject(new Error('Native test timeout')), 5000));
            return await Promise.race([browser.runtime.sendNativeMessage('test.host', 'hello').then(r => r.echo), timeout]);
            """#, arguments: [:], in: nil, contentWorld: .page)
        #expect(reply as? String == "hello")
        #expect(manager.nativeMessaging.count == 0)
        let persistent = try await web.callAsyncJavaScript(#"""
            return await new Promise((resolve, reject) => {
                const timer = setTimeout(() => reject(new Error('Port timeout')), 5000);
                globalThis.nativePort = browser.runtime.connectNative('test.host');
                nativePort.onDisconnect.addListener(() => { globalThis.nativeDisconnected = true; });
                nativePort.onMessage.addListener(r => { clearTimeout(timer); resolve(r.echo); });
                nativePort.postMessage('persistent');
            });
            """#, arguments: [:], in: nil, contentWorld: .page)
        #expect(persistent as? String == "persistent")
        #expect(manager.nativeMessaging.count == 1)
        context.setPermissionStatus(.deniedExplicitly, for: .init(rawValue: "nativeMessaging"))
        for _ in 0..<50 where manager.nativeMessaging.count != 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(manager.nativeMessaging.count == 0)
        #expect(!manager.nativeMessaging.authorized(context))
        let denied: Bool = await withCheckedContinuation { continuation in
            manager.nativeMessaging.send("denied", name: "test.host", context: context) { reply, error in
                continuation.resume(returning: reply == nil && error != nil)
            }
        }
        #expect(denied)
        context.setPermissionStatus(.grantedExplicitly, for: .init(rawValue: "nativeMessaging"))
        for message in ["crash", "malformed"] {
            let failed = try await web.callAsyncJavaScript(#"""
                return await Promise.race([
                    browser.runtime.sendNativeMessage('test.host', message).then(() => false, () => true),
                    new Promise(resolve => setTimeout(() => resolve(false), 5000))
                ]);
                """#, arguments: ["message": message], in: nil, contentWorld: .page)
            #expect(failed as? Bool == true)
        }
        _ = try await web.evaluateJavaScript("globalThis.nativePort = browser.runtime.connectNative('test.host'); void 0")
        for _ in 0..<50 where manager.nativeMessaging.count == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(manager.nativeMessaging.count == 1)
        _ = try await web.evaluateJavaScript("nativePort.disconnect(); void 0")
        for _ in 0..<50 where manager.nativeMessaging.count != 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(manager.nativeMessaging.count == 0)
        _ = try await web.evaluateJavaScript("globalThis.nativePort = browser.runtime.connectNative('test.host'); void 0")
        for _ in 0..<50 where manager.nativeMessaging.count == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(manager.nativeMessaging.count == 1)
        manager.closeDocuments(for: context)
        #expect(manager.nativeMessaging.count == 0)
        try await Task.sleep(for: .milliseconds(50))
        let report = manager.diagnosticReport()
        for event in ["nativeRequested", "nativeResolved", "nativeStarted", "nativeFirstSend", "nativeFirstReceive", "nativeClosed", "nativeExited", "nativeRejected"] {
            #expect(report.contains(event))
        }
        #expect(!report.contains("hello"))
        #expect(!report.contains("native@test"))
        try manager.controller.unload(context)
    }
}

@Test func nativeMessageFramingAndAuthorization() throws {
    let first = try NativeMessageFrames.encode(["hello": "世界"])
    let second = try NativeMessageFrames.encode("second")
    var frames = NativeMessageFrames(), decoded: [Data] = []
    for byte in first + second { decoded += try frames.append(Data([byte])) }
    #expect(decoded.count == 2)
    #expect(frames.isEmpty)
    #expect(try JSONSerialization.jsonObject(with: decoded[1], options: .fragmentsAllowed) as? String == "second")
    #expect(throws: (any Error).self) { _ = try frames.append(Data([255, 255, 255, 255])) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseHostManifest-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(#"{"name":"test.host","path":"/usr/bin/true","type":"stdio","allowed_extensions":["allowed@test"]}"#.utf8)
        .write(to: root.appendingPathComponent("test.host.json"))
    let host = try NativeHost.resolve("test.host", extensionID: "allowed@test", directories: [root])
    #expect(host.arguments == [root.appendingPathComponent("test.host.json").path, "allowed@test"])
    #expect(throws: (any Error).self) { _ = try NativeHost.resolve("test.host", extensionID: "foreign@test", directories: [root]) }
    #expect(throws: (any Error).self) { _ = try NativeHost.resolve("../test.host", extensionID: "allowed@test", directories: [root]) }
    #expect(throws: (any Error).self) { _ = try NativeHost.resolve("missing.host", extensionID: "allowed@test", directories: [root]) }
}

// @lat: [[tests#Extension diagnostic logging]]
@Test @MainActor func extensionDiagnosticLogging() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseDiagnosticTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let logger = ExtensionDiagnostics(root: root, maximumBytes: 2048)
    let extensionID = UUID()
    let secret = "NEVER-LOG-test-account-and-secret"
    logger.record(.hostStarted)
    let error = NSError(domain: "WKErrorDomain", code: 4,
        userInfo: [NSLocalizedDescriptionKey: "WASM is not initialized: \(secret)", "payload": secret])
    logger.record(.runtimeError, extensionID: extensionID, fields: ExtensionDiagnostics.errorFields(error))
    let second = ExtensionDiagnostics(root: root, maximumBytes: 2048)
    let report = second.report()
    #expect(report.contains(logger.run.uuidString))
    #expect(report.contains("wasm-not-initialized"))
    #expect(!report.contains(secret))
    #expect(ExtensionDiagnostics.applicationLabel(secret) == "other")
    #expect((try FileManager.default.attributesOfItem(atPath: logger.file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    for index in 0..<50 { second.record(.snapshot, extensionID: extensionID, fields: ["counter": String(index)]) }
    for file in [second.file, second.previousFile] {
        #expect(try Data(contentsOf: file).count <= 2048)
    }
    #expect(second.report().contains("\"counter\":\"49\""))
    // A failed diagnostic write must not break extension behavior or copying.
    let blocked = root.appendingPathComponent("not-a-directory")
    try Data().write(to: blocked)
    let fallback = ExtensionDiagnostics(root: blocked)
    fallback.record(.nativeRequested, extensionID: extensionID)
    #expect(fallback.writeFailed)
    #expect(fallback.report().contains("nativeRequested"))
}

// @lat: [[tests#1Password protocol diagnostic redaction]]
@Test func onePasswordProtocolDiagnosticRedaction() {
    let secret = "NEVER-LOG-ACCOUNT-OR-CREDENTIAL"
    let failure: [String: Any] = ["type": "Failure", "content": ["callbackId": secret,
        "response": ["type": "InvalidBrowserSignature", "content": ["reason": secret]]]]
    let fields = OnePasswordProtocolSummary.fields(failure)
    #expect(fields == ["protocolType": "Failure", "protocolCodes": "InvalidBrowserSignature"])
    let success: [String: Any] = ["type": "Success", "content": ["response": ["password": secret, "type": "Untrusted"]]]
    #expect(OnePasswordProtocolSummary.fields(success) == ["protocolType": "Success"])
    #expect(OnePasswordProtocolSummary.fields(["type": secret]) == ["protocolType": "other"])
    let unknown: [String: Any] = ["type": "Failure", "content": ["response": ["type": secret, "error": secret]]]
    #expect(OnePasswordProtocolSummary.fields(unknown) == ["protocolType": "Failure"])
    let notification: [String: Any] = ["type": "NotificationModern", "content": [
        "content": ["type": "BrowserVerificationFailed", "content": "BrowserSignatureInvalid"],
        "browser_state": ["type": "Untrusted", "content": ["id": Data("dev.yury.browse.prototype".utf8).base64EncodedString()]]]]
    let status = OnePasswordProtocolSummary.fields(notification)
    #expect(status["reportedBrowserID"] == "dev.yury.browse.prototype")
    #expect(status["protocolCodes"] == "BrowserSignatureInvalid,BrowserVerificationFailed")
    let malformed: [String: Any] = ["type": "NotificationModern", "content": ["browser_state": ["type": "Untrusted",
        "content": ["id": Data("/private/account/path".utf8).base64EncodedString()]]]]
    #expect(OnePasswordProtocolSummary.fields(malformed)["reportedBrowserID"] == nil)
}

private struct WasmRestartProfile: Codable {
    let extensionStore: UUID
    let websiteStore: UUID
    let origin: URL
}

// @lat: [[tests#Firefox WASM process restart]]
@Test @MainActor func firefoxWasmProcessRestart() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard #available(macOS 15.4, *), let package = environment["BROWSE_TEST_FIREFOX_PACKAGE"],
          let profilePath = environment["BROWSE_TEST_WASM_PROFILE"],
          let phase = environment["BROWSE_TEST_WASM_PHASE"], ["install", "restore"].contains(phase) else { return }
    _ = NSApplication.shared
    let root = URL(fileURLWithPath: profilePath)
    let metadata = root.appendingPathComponent("probe.json")
    let saved = phase == "restore" ? try JSONDecoder().decode(WasmRestartProfile.self, from: Data(contentsOf: metadata)) : nil
    let extensionStore = saved?.extensionStore ?? UUID(), websiteStore = saved?.websiteStore ?? UUID()
    let manager = ExtensionManager(root: root.appendingPathComponent("installed"), storageIdentifier: extensionStore,
        websiteDataStore: WKWebsiteDataStore(forIdentifier: websiteStore), notifications: TestNotifications())
    manager.presentsWindows = false
    // This probe never contacts the real desktop app, signs in, or reads vaults.
    manager.nativeMessaging.resolve = { _, _ in NativeHost(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: []) }
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), extensionManager: manager)
    await manager.restorationTask?.value
    _ = store.controller(for: store.selectedTab.pages[0])
    if phase == "install" {
        try await manager.importExtension(from: URL(fileURLWithPath: package))
        try await manager.enable(true, id: try #require(manager.records.first?.id)) { _, _ in true }
    }
    let id = try #require(manager.records.first?.id)
    let context = try #require(manager.contexts[id])
    defer { manager.closeDocuments(for: context); try? manager.controller.unload(context) }
    #expect(manager.isEnabled(id))
    if let saved { #expect(context.baseURL == saved.origin) }
    try await context.loadBackgroundContent()
    func wasmSucceeded() -> Bool {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return manager.diagnosticReport().split(separator: "\n").contains { line in
            guard let event = try? decoder.decode(ExtensionDiagnostics.Entry.self, from: Data(line.utf8)) else { return false }
            return event.run == manager.diagnostics.run && event.extensionID == id && event.event == .wasmOperation
                && event.fields["page"] == "background" && event.fields["stage"] == "succeeded"
                && ["instantiate", "instantiateStreaming"].contains(event.fields["phase"] ?? "")
        }
    }
    for _ in 0..<100 where !wasmSucceeded() { try await Task.sleep(for: .milliseconds(100)) }
    #expect(wasmSucceeded(), "Background WASM did not instantiate: \(manager.diagnosticReport())")
    manager.performAction(id, pageID: store.selectedTab.focusedPane)
    for _ in 0..<100 where manager.documents.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
    let document = try #require(manager.documents.values.first)
    var ready = false
    for _ in 0..<100 {
        ready = (try? await document.web.evaluateJavaScript("document.body?.innerText.includes('Welcome to 1Password')")) as? Bool == true
        if ready { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    #expect(ready)
    let signIn = try await document.web.callAsyncJavaScript(#"""
        for (let i=0; i<3; i++) {
            const button = [...document.querySelectorAll('button')].find(b => b.textContent.trim() === "Don't enable");
            if (!button) break;
            button.click();
            await new Promise(resolve => setTimeout(resolve, 200));
        }
        return document.body.innerText.includes('Sign in');
        """#, arguments: [:], in: nil, contentWorld: .page)
    #expect(signIn as? Bool == true)
    try await Task.sleep(for: .seconds(2))
    #expect(context.errors.isEmpty, "\(context.errors.map(\.localizedDescription))")
    if phase == "install" {
        try JSONEncoder().encode(WasmRestartProfile(extensionStore: extensionStore, websiteStore: websiteStore, origin: context.baseURL)).write(to: metadata)
    }
}
