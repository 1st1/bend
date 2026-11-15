import AppKit
import SwiftUI
import Testing
import BrowseCore
@testable import Browse

// @lat: [[lat.md/tests/pane-layout-tests#Overflowing pane layouts]]
@Test @MainActor func overflowingPaneLayouts() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("PaneOverflow-\(UUID())")
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    defer { store.stopWindow(); try? FileManager.default.removeItem(at: root) }
    let pages = [Page(), Page(isPinned: true), Page()]
    var tab = BrowserTab(pages: pages)
    tab.layout = .split(id: UUID(), axis: .horizontal, fraction: 0.5, first: .pane(pages[0].id),
        second: .split(id: UUID(), axis: .vertical, fraction: 0.5, first: .pane(pages[1].id), second: .pane(pages[2].id)))
    var next = store.session
    next.workspaces = [Workspace(name: "Tabs", tabs: [tab])]; next.selectedTab = tab.id
    store.session = next
    let controllers = pages.map { store.controller(for: $0) }
    for controller in controllers {
        controller.isStartPage = false
        controller.webView.loadHTMLString("<title>Preserved page</title><body style='background:#ff8800'><input value='unsaved'></body>", baseURL: nil)
    }
    let host = MountedTabHost(frame: NSRect(x: 0, y: 0, width: 1100, height: 800))
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = host; window.setFrameOrigin(NSPoint(x: -10000, y: -10000)); window.orderFront(nil)
    defer { window.orderOut(nil); window.contentView = nil }
    func settle() async throws {
        host.update(store: store, environment: EnvironmentValues())
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
    }
    try await settle()
    for controller in controllers {
        for _ in 0..<100 where controller.webView.isLoading { try await Task.sleep(for: .milliseconds(10)) }
        _ = try await controller.webView.evaluateJavaScript("window.preserved = 'yes'")
    }
    let roomy = PaneGeometry(layout: tab.layout, viewport: host.bounds.size)
    #expect(roomy.clippedPaneIDs(in: host.bounds.size).isEmpty)
    window.setContentSize(NSSize(width: 560, height: 420))
    try await settle()
    let geometry = PaneGeometry(layout: tab.layout, viewport: host.bounds.size)
    let clipped = geometry.clippedPaneIDs(in: host.bounds.size)
    #expect(clipped == [pages[1].id, pages[2].id])
    let regions = geometry.overflowRegions(layout: tab.layout, in: host.bounds.size)
    #expect(regions.count == 1)
    #expect(regions.first?.paneIDs == clipped)
    #expect(regions.first?.frame == CGRect(x: 346, y: 0, width: 214, height: 420))
    let web = controllers[0].webView
    let point = host.convert(NSPoint(x: web.bounds.midX, y: web.bounds.midY), from: web)
    let visibleHit = host.hitTest(point)
    #expect(visibleHit === web || visibleHit?.isDescendant(of: web) == true)
    // The placeholder must take hits rather than exposing a cropped WebKit surface.
    let hit = host.hitTest(NSPoint(x: 450, y: host.bounds.midY))
    #expect(!controllers.contains { hit === $0.webView || hit?.isDescendant(of: $0.webView) == true })
    if let path = ProcessInfo.processInfo.environment["BEND_OVERFLOW_SNAPSHOT"], let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
    window.setContentSize(NSSize(width: 1100, height: 800))
    try await settle()
    for (page, controller) in zip(pages, controllers) {
        #expect(store.existingController(for: page.id) === controller)
        #expect(try await controller.webView.evaluateJavaScript("window.preserved") as? String == "yes")
    }
    store.separatePanes(clipped, from: tab.id)
    try await settle()
    #expect(store.session.isValid)
    let tabs = store.session.workspaces.flatMap(\.tabs)
    #expect(tabs.count == 3 && tabs.allSatisfy { $0.pages.count == 1 })
    #expect(Set(tabs.flatMap(\.pages).map(\.id)) == Set(pages.map(\.id)))
    #expect(tabs.flatMap(\.pages).first { $0.id == pages[1].id }?.isPinned == true)
    #expect(!store.canReopenClosed)
    for (page, controller) in zip(pages, controllers) {
        #expect(store.existingController(for: page.id) === controller)
        #expect(try await controller.webView.evaluateJavaScript("document.querySelector('input').value") as? String == "unsaved")
    }
    let onlyHorizontal = PaneGeometry(layout: tab.layout, viewport: CGSize(width: 560, height: 800))
    #expect(onlyHorizontal.clippedPaneIDs(in: CGSize(width: 560, height: 800)) == [pages[1].id, pages[2].id])
}
