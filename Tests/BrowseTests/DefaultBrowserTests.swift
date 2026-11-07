import AppKit
import Testing
@testable import Browse

// @lat: [[tests#Default browser selection]]
@Test @MainActor func defaultBrowserSelection() async {
    let app = URL(fileURLWithPath: "/Applications/Bend.app")
    let identifier = "dev.yury.browse.prototype"
    var handlers = ["http": "other", "https": "other"]
    var requests: [String] = []
    let browser = DefaultBrowser(applicationURL: app, bundleIdentifier: identifier, handler: { handlers[$0.scheme!] }) { url, scheme in
        #expect(url == app)
        requests.append(scheme)
        // A system browser confirmation can update both schemes at once.
        handlers = ["http": identifier, "https": identifier]
    }
    #expect(!browser.isDefault)
    await browser.makeDefault()
    #expect(requests == ["https"])
    #expect(browser.isDefault)
    #expect(!browser.isRequesting)
    #expect(browser.error == nil)

    handlers["http"] = "other"
    browser.refresh()
    #expect(!browser.isDefault)
    requests.removeAll()
    await browser.makeDefault()
    #expect(requests == ["http"])
    #expect(browser.isDefault)

    let cancelled = DefaultBrowser(applicationURL: app, bundleIdentifier: identifier, handler: { _ in "other" }) { _, _ in
        throw NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
    }
    await cancelled.makeDefault()
    #expect(!cancelled.isDefault)
    #expect(!cancelled.isRequesting)
    #expect(cancelled.error == nil)
    let failed = DefaultBrowser(applicationURL: app, bundleIdentifier: identifier, handler: { _ in "other" }) { _, _ in
        throw NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)
    }
    await failed.makeDefault()
    #expect(!failed.isDefault)
    #expect(!failed.isRequesting)
    #expect(failed.error != nil)
}

// @lat: [[tests#External web links]]
@Test @MainActor func externalWebLinks() throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendExternalURLs-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let windows = BrowserWindows(root: root, persistentExtensions: false)
    let delegate = AppDelegate(browserWindows: windows)
    defer { windows.prepareToQuit(); for context in windows.windows { context.window.close() } }
    let urls = [URL(string: "https://example.invalid/first?x=1#fragment")!, URL(string: "http://example.invalid/second")!]
    delegate.application(NSApp, open: urls + [URL(string: "file:///tmp/private.txt")!, URL(string: "browse://start")!])
    #expect(windows.windows.isEmpty)
    delegate.restoreBrowserWindows(show: false)
    let first = try #require(windows.active)
    let originalTabs = first.store.session.workspaces.flatMap(\.tabs)
    #expect(originalTabs.suffix(2).flatMap(\.pages).map(\.address) == urls.map(\.absoluteString))
    #expect(first.store.selectedTab.pages[0].address == urls.last!.absoluteString)
    // Queue drains once, without replacing existing tabs when more links arrive.
    delegate.restoreBrowserWindows(show: false)
    #expect(first.store.session.workspaces.flatMap(\.tabs).count == originalTabs.count)
    let second = windows.newWindow(show: false)
    second.window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    let incoming = URL(string: "https://example.invalid/third")!
    delegate.application(NSApp, open: [incoming])
    #expect(second.store.selectedTab.pages[0].address == incoming.absoluteString)
    #expect(first.store.session.workspaces.flatMap(\.tabs).map(\.id) == originalTabs.map(\.id))
    #expect(second.window.childWindows?.contains { second.addressPanel.owns($0) && $0.isVisible } != true)
}

// @lat: [[tests#Local web documents]]
@Test @MainActor func localWebDocuments() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendLocalHTML-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("example.html")
    try "<title>Local page</title><script src='sibling.js'></script>".write(to: file, atomically: true, encoding: .utf8)
    try "window.localDocumentToken = 'loaded';".write(to: root.appendingPathComponent("sibling.js"), atomically: true, encoding: .utf8)
    #expect(LocalWebDocument.accepts(file))
    #expect(LocalWebDocument.accepts(root.appendingPathComponent("example.XHTML")))
    #expect(!LocalWebDocument.accepts(URL(string: "file://remote.example/example.html")!))
    #expect(!LocalWebDocument.accepts(root.appendingPathComponent("private.txt")))
    #expect(LocalWebDocument.contains(file, in: root))
    #expect(!LocalWebDocument.contains(root.appendingPathComponent("../outside.html"), in: root))
    #expect(!LocalWebDocument.contains(URL(string: "https://example.com")!, in: root))
    let windows = BrowserWindows(root: root.appendingPathComponent("profile"), persistentExtensions: false)
    let delegate = AppDelegate(browserWindows: windows)
    defer { windows.prepareToQuit(); for context in windows.windows { context.window.close() } }
    delegate.application(NSApp, open: [file])
    delegate.restoreBrowserWindows(show: false)
    let store = try #require(windows.active?.store)
    let page = store.selectedTab.pages[0]
    #expect(page.address == file.absoluteString)
    // A newly created controller also exercises restoration from the saved URL.
    for controller in [store.controller(for: page), PageController(address: page.address)] {
        for _ in 0..<100 {
            if (try? await controller.webView.evaluateJavaScript("window.localDocumentToken")) as? String == "loaded" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(try await controller.webView.evaluateJavaScript("window.localDocumentToken") as? String == "loaded")
        #expect(controller.webView.title == "Local page")
        #expect(controller.error == nil)
        controller.webView.stopLoading()
    }
}
