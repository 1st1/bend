import AppKit
import BrowseCore
import Testing
@testable import Browse

// @lat: [[tests#Page zoom shortcuts]]
@Test @MainActor func pageZoomShortcuts() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendZoom-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let windows = BrowserWindows(root: root, persistentExtensions: false)
    windows.restore(show: false)
    let context = try #require(windows.active)
    let store = context.store
    let tab = BrowserTab(pages: [Page(address: "browse://start"), Page(address: "browse://start")])
    store.session.workspaces = [Workspace(name: "Test", tabs: [tab])]
    store.session.selectedTab = tab.id
    let pages = tab.pages.map { store.controller(for: $0) }
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 500))
    let hosts = pages.enumerated().map { index, page in
        let host = WebSurfaceHost(frame: NSRect(x: index * 500, y: 0, width: 500, height: 500))
        host.update(webView: page.webView, topContentInset: 36)
        container.addSubview(host)
        page.isStartPage = false
        page.webView.loadHTMLString("<p>Page zoom</p><input value='keep me'>", baseURL: nil)
        return host
    }
    context.window.contentView = container
    context.window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    context.window.makeKeyAndOrderFront(nil)
    let delegate = AppDelegate(browserWindows: windows)
    let oldMenu = NSApp.mainMenu
    delegate.installMenus()
    defer {
        NSApp.mainMenu = oldMenu
        windows.prepareToQuit()
        for session in windows.windows { session.window.close() }
    }
    for page in pages {
        for _ in 0..<40 {
            if (try? await page.webView.evaluateJavaScript("!!document.querySelector('input')")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    let viewMenu = try #require(NSApp.mainMenu?.item(withTitle: "View")?.submenu)
    let zoomIn = try #require(viewMenu.item(withTitle: "Zoom In"))
    let zoomOut = try #require(viewMenu.item(withTitle: "Zoom Out"))
    let reset = try #require(viewMenu.item(withTitle: "Actual Size"))
    func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = .command) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: context.window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        #expect(try #require(NSApp.mainMenu).performKeyEquivalent(with: event))
    }
    let origin = try await pages[0].webView.evaluateJavaScript("performance.timeOrigin") as? Double
    #expect(pages.allSatisfy { $0.webView.allowsMagnification })
    pages[0].webView.setMagnification(2, centeredAt: NSPoint(x: 250, y: 250))
    #expect(pages[0].webView.magnification == 2)
    #expect(pages[0].webView.pageZoom == 1)
    #expect(pages[1].webView.magnification == 1)
    try key("=", code: 24)
    #expect(pages[0].webView.pageZoom == 1.1)
    #expect(pages[0].webView.magnification == 2)
    pages[0].webView.setMagnification(1, centeredAt: NSPoint(x: 250, y: 250))
    #expect(pages[1].webView.pageZoom == 1)
    try key("+", code: 24, modifiers: [.command, .shift])
    #expect(pages[0].webView.pageZoom == 1.25)
    try key("-", code: 27)
    #expect(pages[0].webView.pageZoom == 1.1)
    try key("0", code: 29)
    #expect(pages[0].webView.pageZoom == 1)
    #expect(!delegate.validateMenuItem(reset))
    store.focus(tab.pages[1].id)
    try key("-", code: 27)
    #expect(pages[1].webView.pageZoom == 0.9)
    #expect(pages[0].webView.pageZoom == 1)
    for _ in 0..<30 { delegate.zoomPage(zoomIn) }
    #expect(pages[1].webView.pageZoom == 5)
    #expect(!delegate.validateMenuItem(zoomIn))
    for _ in 0..<30 { delegate.zoomPage(zoomOut) }
    #expect(pages[1].webView.pageZoom == 0.25)
    #expect(!delegate.validateMenuItem(zoomOut))
    try key("0", code: 29)
    #expect(pages[1].webView.pageZoom == 1)
    #expect(try await pages[0].webView.evaluateJavaScript("performance.timeOrigin") as? Double == origin)
    #expect(try await pages[0].webView.evaluateJavaScript("document.querySelector('input').value") as? String == "keep me")
    #expect(store.zoomedPane == nil)
    pages[1].isStartPage = true
    #expect(!delegate.validateMenuItem(zoomIn))
    delegate.zoomPage(zoomIn)
    #expect(pages[1].webView.pageZoom == 1)
    pages[1].isStartPage = false
    hosts[1].isHidden = true
    #expect(!delegate.validateMenuItem(zoomIn))
}
