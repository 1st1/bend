import AppKit
import Testing
import BrowseCore
@testable import Browse

// @lat: [[tests#Floating sidebar interaction]]
@Test @MainActor func floatingSidebarInteraction() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendFloatingSidebar-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let owner = BrowserWindows(root: root, persistentExtensions: false)
    owner.restore(show: false)
    let context = try #require(owner.active)
    let store = context.store
    store.onAddressRequested = nil
    let window = context.window
    defer { owner.prepareToQuit(); window.close() }
    let firstTab = store.selectedTab.id
    store.split(.vertical)
    store.newTab()
    let secondTab = store.selectedTab.id
    store.select(firstTab)
    store.sidebarVisible = false
    window.makeKeyAndOrderFront(nil)
    window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    func settle() async throws {
        for _ in 0..<5 {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
        }
    }
    func descendants<T: NSView>(_ type: T.Type, _ view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, $0) }
    }
    try await settle()
    let content = try #require(window.contentView)
    let tracker = try #require(descendants(FloatingSidebarTrackingView.self, content).first)
    let mounted = try #require(descendants(MountedTabHost.self, content).first)
    let originalFrame = mounted.frame
    let originalHost = try #require(mounted.mounted[firstTab])
    let page = store.selectedTab.pages[0]
    let controller = store.controller(for: page)
    let originalWeb = controller.webView
    controller.isStartPage = false
    originalWeb.loadHTMLString("<input value='draft'><script>window.sidebarProbe = true</script>", baseURL: nil)
    for _ in 0..<50 {
        if (try? await originalWeb.evaluateJavaScript("window.sidebarProbe")) as? Bool == true { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    try await settle()
    let originalBounds = originalWeb.bounds
    try #require(originalBounds.width > 100 && originalBounds.height > 100)
    _ = try await originalWeb.evaluateJavaScript("window.sidebarResizes = 0; addEventListener('resize', () => sidebarResizes++)")
    func move(_ point: NSPoint) throws {
        let event = try #require(NSEvent.mouseEvent(with: .mouseMoved,
            location: tracker.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        tracker.mouseMoved(with: event)
    }
    // Hovering ordinary page content doesn't reveal it; the edge does.
    try move(NSPoint(x: 100, y: 200))
    #expect(!store.sidebarFloating)
    try move(NSPoint(x: 3, y: 200))
    try await settle()
    #expect(store.sidebarFloating)
    #expect(!store.sidebarVisible)
    #expect(mounted.frame == originalFrame)
    #expect(mounted.mounted[firstTab] === originalHost)
    #expect(store.existingController(for: page.id)?.webView === originalWeb)
    #expect(originalWeb.bounds == originalBounds)
    try move(NSPoint(x: 120, y: 200))
    try await settle()
    #expect(store.sidebarFloating)
    // Actual native hit testing and mouse dispatch must reach the overlay tab.
    let row = try #require(descendants(TabDragSourceView.self, content).first { $0.tabID == secondTab })
    let point = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
    let frameView = try #require(content.superview)
    #expect(frameView.hitTest(frameView.convert(point, from: nil)) === row)
    try sendPaneMouse(.leftMouseDown, at: point, to: window)
    try sendPaneMouse(.leftMouseUp, at: point, to: window)
    try await settle()
    #expect(store.selectedTab.id == secondTab)
    #expect(store.sidebarFloating)
    #expect(mounted.frame == originalFrame)
    store.select(firstTab)
    try await settle()
    #expect(try await originalWeb.evaluateJavaScript("document.querySelector('input').value") as? String == "draft")
    // A pane header under the panel cannot capture presses through it.
    let lower = try #require(descendants(PaneDragSourceView.self, content).first {
        $0.onHover != nil && !$0.isHiddenOrHasHiddenAncestor &&
        tracker.convert($0.convert(NSPoint(x: 10, y: $0.bounds.midY), to: nil), from: nil).y > 200
    })
    let covered = lower.convert(NSPoint(x: 10, y: lower.bounds.midY), to: nil)
    #expect(FloatingSidebarTrackingView.covers(covered, in: window))
    try sendPaneMouse(.leftMouseDown, at: covered, to: window)
    #expect(!window.capturesPaneGesture)
    try sendPaneMouse(.leftMouseUp, at: covered, to: window)
    // Leaving briefly and reentering cancels dismissal; sustained departure hides it.
    try move(NSPoint(x: 500, y: 200))
    try await Task.sleep(for: .milliseconds(60))
    try move(NSPoint(x: 100, y: 200))
    try await settle()
    #expect(store.sidebarFloating)
    try move(NSPoint(x: 500, y: 200))
    try await settle()
    #expect(!store.sidebarFloating)
    #expect(mounted.frame == originalFrame)
    #expect(originalWeb.bounds == originalBounds)
    #expect(try await originalWeb.evaluateJavaScript("window.sidebarResizes") as? Int == 0)
    try move(NSPoint(x: 3, y: 200))
    store.sidebarVisible = true
    try await settle()
    #expect(!store.sidebarFloating)
    try move(NSPoint(x: 3, y: 200))
    #expect(!store.sidebarFloating)
    store.sidebarVisible = false
    store.isFullScreen = true
    try await settle()
    try move(NSPoint(x: 3, y: 10))
    #expect(store.sidebarFloating)
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
    #expect(!store.sidebarFloating)
}
