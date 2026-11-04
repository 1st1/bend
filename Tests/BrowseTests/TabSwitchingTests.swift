import AppKit
import SwiftUI
import Testing
import WebKit
import BrowseCore
@testable import Browse

// @lat: [[tests#Mounted tab switching]]
@Test @MainActor func mountedTabSwitching() async throws {
    guard #available(macOS 15.4, *) else { return }
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseMountedTabs-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let server = try await ExtensionHTTPFixture.start()
    defer { server.listener.cancel() }
    let address = "http://127.0.0.1:\(server.port)/"
    let manager = ExtensionManager(root: root.appendingPathComponent("extensions"), persistent: false,
        websiteDataStore: .nonPersistent(), notifications: TestNotifications())
    manager.presentsWindows = false
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), extensionManager: manager)
    let first = BrowserTab(pages: [Page(address: address), Page(address: address)])
    let second = BrowserTab(pages: [Page(address: address)])
    let unvisited = BrowserTab(pages: [Page(address: address)])
    store.session.workspaces = [Workspace(name: "Test", tabs: [first, second, unvisited])]
    store.session.selectedTab = first.id
    let host = MountedTabHost(frame: NSRect(x: 0, y: 0, width: 1100, height: 700))
    let window = BrowseWindow(contentRect: host.frame,
        styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.toolbarStyle = .unified
    window.toolbar = NSToolbar(identifier: "MountedTabTest")
    window.isMovableByWindowBackground = true
    window.contentView = host
    window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    window.orderFront(nil)
    // Keep the window offscreen; all pages and extension storage are disposable.
    defer { window.orderOut(nil); window.contentView = nil }
    func update() { host.update(store: store, environment: EnvironmentValues()); host.layoutSubtreeIfNeeded() }
    func settle() async throws {
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    update()
    try await settle()
    let firstHost = try #require(host.mounted[first.id])
    let controller = try #require(store.existingController(for: first.pages[0].id))
    let web = controller.webView
    for _ in 0..<50 {
        if (try? await web.evaluateJavaScript("document.body?.textContent.includes('Fixture')")) as? Bool == true { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    try await settle()
    let parent = try #require(web.superview)
    for expression in ["navigator.userAgent", "window.requestUserAgent"] {
        let userAgent = try #require(try await web.evaluateJavaScript(expression) as? String)
        #expect(userAgent.contains(" Version/"))
        #expect(userAgent.contains(" Safari/605.1.15 Browse/0.1"))
    }
    func dragHandles(in view: NSView) -> [PaneDragSourceView] {
        (view as? PaneDragSourceView).map { [$0] } ?? view.subviews.flatMap { dragHandles(in: $0) }
    }
    let handles = dragHandles(in: firstHost)
    #expect(handles.filter { $0.onHover != nil }.count == 2)
    let source = try #require(handles.first { $0.pageID != first.pages[0].id })
    let otherWeb = try #require(store.existingController(for: first.pages[1].id)?.webView)
    let otherParent = try #require(otherWeb.superview)
    let originalBounds = web.bounds
    #expect(originalBounds.width > 100 && originalBounds.height > 100)
    // Responsive layout must follow the real pane width, including after a
    // resize while keeping the same live document mounted.
    _ = try await web.evaluateJavaScript("""
        const responsiveStyle = document.createElement('style');
        responsiveStyle.textContent = 'body { --pane-layout: wide; } @media (max-width: 450px) { body { --pane-layout: narrow; } }';
        document.head.append(responsiveStyle);
        window.paneResizeEvents = 0;
        window.addEventListener('resize', () => window.paneResizeEvents++);
        """)
    func checkResponsive(_ expected: String) async throws {
        let innerWidth = try #require(try await web.evaluateJavaScript("innerWidth") as? Double)
        print("PANE_VIEWPORT", expected, "native", web.bounds.width, "css", innerWidth)
        #expect(abs(innerWidth - web.bounds.width) <= 1)
        #expect(try await web.evaluateJavaScript("getComputedStyle(document.body).getPropertyValue('--pane-layout').trim()") as? String == expected)
    }
    try await checkResponsive("wide")
    window.setContentSize(NSSize(width: 720, height: 700))
    update()
    try await settle()
    #expect(web.bounds.width < 450)
    try await checkResponsive("narrow")
    window.setContentSize(NSSize(width: 1100, height: 700))
    update()
    try await settle()
    try await checkResponsive("wide")
    #expect((try await web.evaluateJavaScript("window.paneResizeEvents") as? Int ?? 0) >= 2)
    #expect(web.window === window)
    if #available(macOS 26.0, *) {
        let rect = web.convert(web.bounds, to: host)
        #expect(abs(host.bounds.maxY - rect.maxY - 1) < 1)
    }
    #expect(host.mounted.count == 1)
    #expect(store.existingController(for: second.pages[0].id) == nil)
    #expect(store.existingController(for: unvisited.pages[0].id) == nil)
    let stamp = try await web.evaluateJavaScript("performance.timeOrigin") as? Double
    _ = try await web.evaluateJavaScript("""
        window.tabSwitchToken = 'retained';
        document.body.innerHTML = '<input id="draft"><div style="height:3000px"></div>';
        document.getElementById('draft').value = 'unsaved input';
        window.scrollTo(0, 400);
        """)
    try await settle()
    let scroll = try await web.evaluateJavaScript("scrollY") as? Double
    #expect((scroll ?? 0) > 0)

    store.select(second.id)
    update()
    try await settle()
    #expect(host.mounted[first.id] === firstHost)
    #expect(firstHost.isHidden)
    #expect(web.superview === parent)
    #expect(web.isHiddenOrHasHiddenAncestor)
    #expect(web.window === window)
    #expect(host.mounted[second.id]?.isHidden == false)
    // A different tab's zoom must not replace hidden tabs' layouts.
    store.toggleZoom(second.focusedPane)
    update()
    try await settle()
    #expect(otherWeb.superview === otherParent)
    #expect(otherWeb.isDescendant(of: firstHost))
    let hiddenFrame = firstHost.frame
    window.setContentSize(NSSize(width: 1200, height: 750))
    host.layoutSubtreeIfNeeded()
    #expect(firstHost.frame == hiddenFrame)

    store.select(first.id)
    update()
    try await settle()
    #expect(host.mounted[first.id] === firstHost)
    #expect(!web.isHiddenOrHasHiddenAncestor)
    #expect(web.superview === parent)
    #expect(otherWeb.superview === otherParent)
    #expect(firstHost.frame == host.bounds)
    #expect(try await web.evaluateJavaScript("window.tabSwitchToken") as? String == "retained")
    #expect(try await web.evaluateJavaScript("document.getElementById('draft').value") as? String == "unsaved input")
    #expect(try await web.evaluateJavaScript("performance.timeOrigin") as? Double == stamp)
    #expect(try await web.evaluateJavaScript("scrollY") as? Double == scroll)
    #expect(host.mounted[unvisited.id] == nil)
    #expect(store.existingController(for: unvisited.pages[0].id) == nil)

    // Send a complete header-to-page gesture through NSWindow, rather than
    // calling a drag destination or hit-test override directly.
    let downPoint = source.convert(NSPoint(x: source.bounds.midX, y: source.bounds.midY), to: nil)
    try sendPaneMouse(.leftMouseDown, at: downPoint, to: window)
    for x in [0.2, 0.5, 0.8] {
        for y in [0.2, 0.5, 0.8] {
            let point = web.convert(NSPoint(x: web.bounds.width * x, y: web.bounds.height * y), to: nil)
            try sendPaneMouse(.leftMouseDragged, at: point, to: window)
            #expect(source.dragSurface?.target?.pageID == first.pages[0].id)
            #expect(source.dragSurface?.target?.dropEdge != nil)
        }
    }
    let dropPoint = web.convert(NSPoint(x: web.bounds.midX, y: web.bounds.height * (web.isFlipped ? 0.2 : 0.8)), to: nil)
    try sendPaneMouse(.leftMouseDragged, at: dropPoint, to: window)
    #expect(source.dragSurface?.target?.dropEdge == .top)
    try sendPaneMouse(.leftMouseUp, at: dropPoint, to: window)
    #expect(source.dragSurface == nil)
    #expect(store.selectedTab.layout.paneIDs == [first.pages[1].id, first.pages[0].id])
    update()
    try await settle()
    #expect(web.superview === parent)
    #expect(otherWeb.superview === otherParent)
    #expect(try await web.evaluateJavaScript("window.tabSwitchToken") as? String == "retained")
    #expect(try await web.evaluateJavaScript("document.getElementById('draft').value") as? String == "unsaved input")
    #expect(try await web.evaluateJavaScript("performance.timeOrigin") as? Double == stamp)

    let secondHost = try #require(host.mounted[second.id])
    store.closeTab(second.id)
    update()
    #expect(host.mounted[second.id] == nil)
    #expect(secondHost.superview == nil)
    #expect(store.existingController(for: second.pages[0].id) == nil)
    // An extension can close a pane while its tab is hidden.
    store.select(unvisited.id)
    update()
    store.closePage(first.pages[1].id)
    update()
    try await settle()
    #expect(!otherWeb.isDescendant(of: firstHost))
    #expect(store.existingController(for: first.pages[1].id) == nil)
}
