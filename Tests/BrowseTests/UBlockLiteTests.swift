import AppKit
import Testing
import WebKit
@testable import Browse

// @lat: [[tests#Safari uBlock Lite compatibility]]
@Test(.timeLimit(.minutes(1))) @MainActor func safariUBlockLiteSmoke() async throws {
    guard #available(macOS 15.4, *),
          let path = ProcessInfo.processInfo.environment["BROWSE_TEST_UBLOCK_SAFARI_PACKAGE"] else { return }
    let package = URL(fileURLWithPath: path)
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseUBlockLite-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = ExtensionManager(root: root.appendingPathComponent("installed"), persistent: false,
        websiteDataStore: .nonPersistent(), notifications: TestNotifications())
    manager.presentsWindows = false
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), extensionManager: manager)
    // This path matches the package's unmodified EasyList block rule.
    let server = try await ExtensionHTTPFixture.start(scriptPath: "/ads/!rotator/banner.js")
    defer { server.listener.cancel() }
    let page = store.selectedTab.pages[0]
    let pageController = store.controller(for: page)
    let web = pageController.webView
    let url = URL(string: "http://127.0.0.1:\(server.port)/")!
    func loadFixture() async throws {
        pageController.navigate(url.absoluteString)
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(100))
            if !web.isLoading, web.url == url,
               (try? await web.evaluateJavaScript("document.readyState === 'complete'")) as? Bool == true { return }
        }
        throw NSError(domain: "Browse.UBlockLiteTest", code: 1)
    }
    try await loadFixture()
    try #require(try await web.evaluateJavaScript("window.blockedScriptRan === true") as? Bool == true)
    try await manager.importExtension(from: package, expectedIdentifier: "safari:net.raymondhill.uBlock-Origin-Lite.Extension")
    let id = try #require(manager.records.first?.id)
    try await manager.enable(true, id: id) { _, _ in true }
    let context = try #require(manager.contexts[id])
    defer { if context.isLoaded { try? manager.controller.unload(context) } }
    try await context.loadBackgroundContent()
    try await Task.sleep(for: .seconds(5))
    print("UBOL_ERRORS", context.errors.map(\.localizedDescription))
    try await loadFixture()
    #expect(try await web.evaluateJavaScript("window.blockedScriptRan === true") as? Bool == false)
    let action = try #require(context.action(for: manager.tabs[page.id]))
    let popup = try #require(action.popupWebView)
    defer { action.closePopup() }
    try await Task.sleep(for: .milliseconds(500))
    // Diagnostic-only access to the actual background page. Read uBlock's
    // already-loaded modules, rather than duplicating its detection logic.
    try #require(context.responds(to: NSSelectorFromString("_backgroundWebView")))
    let background = try #require(context.value(forKey: "_backgroundWebView") as? WKWebView)
    for (name, view) in [("background", background), ("popup", popup)] {
        let detection = try #require(try await view.callAsyncJavaScript("""
            const ext = await import(browser.runtime.getURL('js/ext.js'));
            const config = await import(browser.runtime.getURL('js/config.js'));
            return {
                flavor: ext.webextFlavor,
                scheme: new URL(browser.runtime.getURL('')).protocol,
                strictBlockDefault: config.defaultConfig.strictBlockMode,
                strictBlockCurrent: config.rulesetConfig.strictBlockMode,
                version: browser.runtime.getManifest().version
            };
            """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any])
        #expect(detection["flavor"] as? String == "safari")
        #expect(detection["scheme"] as? String == "safari-web-extension:")
        #expect(detection["strictBlockDefault"] as? Bool == false)
        #expect(detection["strictBlockCurrent"] as? Bool == false)
        let evidence = try JSONSerialization.data(withJSONObject: detection, options: [.sortedKeys])
        print("UBOL_BROWSER_DETECTION", name, String(decoding: evidence, as: UTF8.self))
    }
    #expect(context.baseURL.scheme == "safari-web-extension")
    #expect(try await popup.evaluateJavaScript("browser.runtime.getURL('popup.html') === location.href") as? Bool == true)

    func waitForPopup(_ expression: String) async throws {
        for _ in 0..<200 {
            if (try? await popup.evaluateJavaScript(expression)) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw NSError(domain: "Browse.UBlockLiteTest", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Popup did not settle: \(expression)"])
    }
    try await waitForPopup("!!document.querySelector('.filteringModeSlider[data-level]') && document.body.innerText.includes('127.0.0.1')")
    for level in [0, 1] {
        _ = try await popup.evaluateJavaScript("document.querySelector('.filteringModeSlider span[data-level=\"\(level)\"]').click()")
        try await waitForPopup("!document.body.classList.contains('busy') && document.querySelector('.filteringModeSlider').dataset.level === '\(level)'")
        // The popup schedules its own tab reload after returning to idle.
        // Let that finish before the next mode change or unloading its context.
        try await Task.sleep(for: .seconds(1))
        try await loadFixture()
        #expect(try await web.evaluateJavaScript("window.blockedScriptRan === true") as? Bool == (level == 0))
    }
    action.closePopup()
    try await manager.enable(false, id: id) { _, _ in true }
    try await loadFixture()
    #expect(try await web.evaluateJavaScript("window.blockedScriptRan === true") as? Bool == true)
    try await manager.enable(true, id: id) { _, _ in true }
    try await context.loadBackgroundContent()
    try await Task.sleep(for: .seconds(5))
    try await loadFixture()
    #expect(try await web.evaluateJavaScript("window.blockedScriptRan === true") as? Bool == false)
    print("UBOL_FINAL_ERRORS", context.errors.map(\.localizedDescription))
    #expect(context.errors.isEmpty)
    try await manager.enable(false, id: id) { _, _ in true }
}
