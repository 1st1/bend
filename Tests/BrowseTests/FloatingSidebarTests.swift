import AppKit
import Testing
import BrowseCore
@testable import Browse

// @lat: [[lat.md/tests/sidebar-tests#Floating sidebar interaction]]
@Test(.serialized, arguments: SidebarSide.allCases) @MainActor
func floatingSidebarInteraction(side: SidebarSide) async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendFloatingSidebar-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let owner = BrowserWindows(root: root, persistentExtensions: false)
    owner.restore(show: false)
    let context = try #require(owner.active)
    let store = context.store
    store.sidebarSide = side
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
            location: tracker.convert(NSPoint(x: side == .left ? point.x : tracker.bounds.width - point.x, y: point.y), to: nil), modifierFlags: [], timestamp: 0,
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
    // The panel reaches behind native window controls and over pane titles.
    #expect(tracker.panelRect.minY == 6)
    #expect(tracker.panelRect.height == tracker.bounds.height - 12)
    for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
        let button = try #require(window.standardWindowButton(kind))
        let center = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let hit = frameView.hitTest(frameView.convert(center, from: nil))
        #expect(hit === button || hit?.isDescendant(of: button) == true)
    }
    let pinPoint = tracker.convert(NSPoint(x: tracker.panelRect.maxX - Chrome.sidebarHorizontalInset - 14,
                                          y: Chrome.headerCenterY), to: nil)
    #expect(FloatingSidebarTrackingView.covers(pinPoint, in: window))
    let pinHit = try #require(frameView.hitTest(frameView.convert(pinPoint, from: nil)))
    #expect(!(pinHit is PaneDragSourceView))
    if let path = ProcessInfo.processInfo.environment["BEND_FLOATING_SIDEBAR_SNAPSHOT"],
       let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
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
        tracker.convert($0.convert(NSPoint(x: side == .left ? 10 : $0.bounds.width - 10, y: $0.bounds.midY), to: nil), from: nil).y > 200
    })
    let headerY = tracker.convert(lower.convert(NSPoint(x: 0, y: lower.bounds.midY), to: nil), from: nil).y
    let covered = tracker.convert(NSPoint(x: tracker.panelRect.midX, y: headerY), to: nil)
    #expect(FloatingSidebarTrackingView.covers(covered, in: window))
    try sendPaneMouse(.leftMouseDown, at: covered, to: window)
    #expect(!window.capturesPaneGesture)
    try sendPaneMouse(.leftMouseUp, at: covered, to: window)
    // Leaving briefly and reentering cancels dismissal; sustained departure hides it.
    try move(NSPoint(x: 500, y: 200))
    #expect(store.sidebarFloating)
    // Deliver reentry in the same main-actor turn: a timed sleep can resume
    // after the dismissal deadline on a loaded runner and simulate a long exit.
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
    try await settle()
    try sendPaneMouse(.leftMouseDown, at: pinPoint, to: window)
    try sendPaneMouse(.leftMouseUp, at: pinPoint, to: window)
    try await settle()
    #expect(store.sidebarVisible)
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
