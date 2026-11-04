import AppKit
import Testing
import UserNotifications
import WebKit
import Network
@testable import Browse

@MainActor private final class TestNotifications: ExtensionNotificationDelivering {
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
        {"manifest_version":2,"name":"Compatibility fixture","version":"1.0",
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
    _ = try await document.web.evaluateJavaScript("[...document.querySelectorAll('button')].find(button => button.textContent.trim() === 'Sign in').click()")
    try await Task.sleep(for: .seconds(4))
    for document in manager.documents.values {
        print("FIREFOX_SIGNIN_PAGE", document.web.url?.absoluteString ?? "nil", try await document.web.evaluateJavaScript("document.body.innerText") ?? "nil")
    }
    print("FIREFOX_SIGNIN_TABS", manager.pages.map(\.address))
    let signin = try #require(manager.pages.first { $0.address.hasPrefix("https://start.1password.com/signin/") })
    let signinController = store.controller(for: signin)
    let signinWeb = signinController.webView
    signinWeb.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
    var signinText = ""
    for _ in 0..<40 {
        signinText = (try? await signinWeb.evaluateJavaScript("document.body?.innerText || ''")) as? String ?? ""
        if signinText.localizedCaseInsensitiveContains("email") { break }
        try await Task.sleep(for: .milliseconds(250))
    }
    print("FIREFOX_ACCOUNT_FORM", signinText.prefix(1500))
    if !signinText.localizedCaseInsensitiveContains("email") {
        print("FIREFOX_ACCOUNT_LOAD", signinWeb.url?.absoluteString ?? "nil", signinWeb.isLoading, signinController.error ?? "no error")
        print("FIREFOX_ACCOUNT_DOM", try await signinWeb.evaluateJavaScript("JSON.stringify({state:document.readyState,title:document.title,body:document.body?.innerHTML.slice(0,2000),scripts:[...document.scripts].map(s=>s.src),resources:performance.getEntriesByType('resource').map(r=>({name:r.name,status:r.responseStatus,duration:r.duration}))})") ?? "nil")
    }
    #expect(signinWeb.url?.scheme == "https")
    #expect(signinText.localizedCaseInsensitiveContains("email"))
    print("FIREFOX_FINAL_ERRORS", context.errors.map(\.localizedDescription))
    try await manager.enable(false, id: id) { _, _ in true }
}
