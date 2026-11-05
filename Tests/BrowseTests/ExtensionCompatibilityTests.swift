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
    _ = try await document.web.callAsyncJavaScript("location.href = address", arguments: ["address": address], in: nil, contentWorld: .page)
    for _ in 0..<100 {
        if document.web.url?.host == "127.0.0.1", !document.web.isLoading { break }
        try await Task.sleep(for: .milliseconds(30))
    }
    #expect(document.web.url?.host == "127.0.0.1")
    #expect(manager.pages.count == pageCount)
    #expect(try await document.web.evaluateJavaScript("sessionStorage.getItem('setupAnswered') === null && !globalThis.browser?.runtime?.id && typeof chrome === 'undefined'") as? Bool == true)
    #expect(try await document.web.callAsyncJavaScript("try { await webkit.messageHandlers.browseExtension.postMessage({operation:'privacySetting', setting:'passwordSavingEnabled', action:'get', details:{}}); return false; } catch { return true; }", arguments: [:], in: nil, contentWorld: .page) as? Bool == true)
    // A website cannot authorize its own promotion into an extension document.
    _ = try await document.web.callAsyncJavaScript("location.href = address", arguments: ["address": url.absoluteString], in: nil, contentWorld: .page)
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
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), extensionManager: manager)
    try await manager.importExtension(from: URL(fileURLWithPath: path))
    let id = try #require(manager.records.first?.id)
    try await manager.enable(true, id: id) { _, _ in true }
    let context = try #require(manager.contexts[id])
    try await context.loadBackgroundContent()
    try await Task.sleep(for: .seconds(25))
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
