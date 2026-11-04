import AppKit
import CryptoKit
import Testing
import WebKit
@testable import Browse

@MainActor private func darkReaderWait(_ web: WKWebView, _ expression: String) async throws {
    for _ in 0..<100 {
        if (try? await web.evaluateJavaScript(expression)) as? Bool == true { return }
        try await Task.sleep(for: .milliseconds(150))
    }
    throw NSError(domain: "Browse.DarkReaderTest", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Timed out: \(expression)"])
}

// @lat: [[tests#Dark Reader compatibility smoke test]]
@Test @MainActor func darkReaderSmoke() async throws {
    guard #available(macOS 15.4, *),
          let path = ProcessInfo.processInfo.environment["BROWSE_TEST_DARK_READER_PACKAGE"] else { return }
    let package = URL(fileURLWithPath: path)
    let digest = SHA256.hash(data: try Data(contentsOf: package)).map { String(format: "%02x", $0) }.joined()
    try #require(digest == "700633395aa2f639a1bed4253e27309eb676f346d599b0ae2b7a0453232e0aec")
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseDarkReader-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = ExtensionManager(root: root.appendingPathComponent("installed"), persistent: false,
        websiteDataStore: .nonPersistent(), notifications: TestNotifications())
    manager.presentsWindows = false
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), extensionManager: manager)
    let server = try await ExtensionHTTPFixture.start()
    defer { server.listener.cancel() }
    try await manager.importExtension(from: package, expectedIdentifier: "gecko:addon@darkreader.org")
    let id = try #require(manager.records.first?.id)
    try await manager.enable(true, id: id) { _, _ in true }
    let context = try #require(manager.contexts[id])
    defer { if context.isLoaded { try? manager.controller.unload(context) } }
    try await context.loadBackgroundContent()
    let page = store.selectedTab.pages[0]
    let pageController = store.controller(for: page)
    let web = pageController.webView
    web.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
    #expect(!web.configuration.websiteDataStore.isPersistent)
    pageController.navigate("http://127.0.0.1:\(server.port)/")
    let dark = "document.documentElement.dataset.darkreaderScheme === 'dark' && document.querySelector('style.darkreader--user-agent') !== null"
    do { try await darkReaderWait(web, dark) }
    catch {
        print("DARK_READER_STARTUP_ERRORS", context.errors.map(\.localizedDescription))
        print("DARK_READER_DOM", try await web.evaluateJavaScript("JSON.stringify({state:document.readyState,scheme:document.documentElement.dataset.darkreaderScheme,styles:[...document.querySelectorAll('style.darkreader')].map(s=>s.className)})") ?? "nil")
        if let popup = context.action(for: manager.tabs[page.id])?.popupWebView {
            try await Task.sleep(for: .seconds(2))
            print("DARK_READER_STARTUP_POPUP", try await popup.evaluateJavaScript("document.body.innerText") ?? "nil")
        }
        throw error
    }
    let colors = try await web.evaluateJavaScript("JSON.stringify({background:getComputedStyle(document.documentElement).backgroundColor,text:getComputedStyle(document.body).color})")
    print("DARK_READER_COLORS", colors ?? "nil")
    #expect(try await web.evaluateJavaScript("getComputedStyle(document.documentElement).backgroundColor === 'rgb(24, 26, 27)'") as? Bool == true)
    #expect(try await web.evaluateJavaScript("getComputedStyle(document.body).color === 'rgb(232, 230, 227)'") as? Bool == true)
    let tab = try #require(manager.tabs[page.id])
    let action = try #require(context.action(for: tab))
    let popup = try #require(action.popupWebView)
    defer { action.closePopup() }
    try await darkReaderWait(popup, "!!document.querySelector('.header__app-toggle .toggle__off')")
    #expect(try await popup.evaluateJavaScript("document.body.innerText.includes('Dark Reader')") as? Bool == true)
    _ = try await popup.evaluateJavaScript("document.querySelector('.header__app-toggle .toggle__off').click()")
    try await darkReaderWait(web, "!document.documentElement.hasAttribute('data-darkreader-scheme')")
    print("DARK_READER_GLOBAL_OFF")
    try await darkReaderWait(popup, "!!document.querySelector('.header__app-toggle .toggle__off.toggle__btn--active')")
    _ = try await popup.evaluateJavaScript("document.querySelector('.header__app-toggle .toggle__on').click()")
    try await darkReaderWait(web, dark)
    print("DARK_READER_GLOBAL_ON")
    try await darkReaderWait(popup, "!!document.querySelector('.header__app-toggle .toggle__on.toggle__btn--active')")
    _ = try await popup.evaluateJavaScript("document.querySelector('.site-toggle').click()")
    try await darkReaderWait(web, "!document.documentElement.hasAttribute('data-darkreader-scheme')")
    print("DARK_READER_SITE_OFF")
    try await darkReaderWait(popup, "!!document.querySelector('.site-toggle:not(.site-toggle--active)')")
    _ = try await popup.evaluateJavaScript("document.querySelector('.site-toggle').click()")
    try await darkReaderWait(web, dark)
    print("DARK_READER_SITE_ON")
    action.closePopup()
    try await manager.enable(false, id: id) { _, _ in true }
    pageController.webView.reload()
    try await darkReaderWait(web, "document.readyState === 'complete' && !document.querySelector('style.darkreader')")
    print("DARK_READER_DISABLED_RELOAD")
    try await manager.enable(true, id: id) { _, _ in true }
    pageController.webView.reload()
    try await darkReaderWait(web, dark)
    print("DARK_READER_ERRORS", context.errors.map(\.localizedDescription))
    try await manager.enable(false, id: id) { _, _ in true }
}
