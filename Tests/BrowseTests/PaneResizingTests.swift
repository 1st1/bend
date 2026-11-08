import AppKit
import SwiftUI
import Testing
import BrowseCore
@testable import Browse

// @lat: [[tests#Divider pointer tracking]]
@Test(.serialized, arguments: [SplitAxis.horizontal, .vertical]) @MainActor
func dividerPointerTracking(axis: SplitAxis) async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseResize-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    let a = Page(address: "browse://start"), b = Page(address: "browse://start"), splitID = UUID()
    var tab = BrowserTab(pages: [a, b])
    tab.layout = .split(id: splitID, axis: axis, fraction: 0.5, first: .pane(a.id), second: .pane(b.id))
    store.session.workspaces = [Workspace(name: "Test", tabs: [tab])]
    store.session.selectedTab = tab.id
    let host = MountedTabHost(frame: NSRect(x: 0, y: 0, width: 1100, height: 900))
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    window.orderFront(nil)
    defer { window.orderOut(nil); window.contentView = nil }
    func settle() async throws {
        host.update(store: store, environment: EnvironmentValues())
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
    }
    func divider() throws -> DividerPlacement {
        try #require(PaneGeometry(layout: store.selectedTab.layout, viewport: host.bounds.size).dividers.first)
    }
    try await settle()
    let initial = try divider()
    let down = host.convert(NSPoint(x: initial.frame.midX, y: host.bounds.height - initial.frame.midY), to: nil)
    let dividerView = try #require(host.hitTest(host.convert(down, from: nil)) as? PaneDividerView)
    #expect(!dividerView.mouseDownCanMoveWindow)
    dividerView.updateTrackingAreas()
    #expect(dividerView.trackingAreas.contains { $0.options.contains(.cursorUpdate) })
    window.invalidateCursorRects(for: dividerView)
    let cursorEvent = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: down,
        modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
        eventNumber: 0, clickCount: 0, pressure: 0))
    dividerView.cursorUpdate(with: cursorEvent)
    #expect(NSCursor.current == (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown))
    defer { NSCursor.arrow.set() }
    try sendPaneMouse(.leftMouseDown, at: down, to: window)
    // Repeating the same pointer coordinate after layout catches feedback from
    // the divider's own movement. Reversals must track without bouncing too.
    for delta in [20.0, 40, 40, 60, 80, 80, 40, 0, -40, -40] {
        let point = NSPoint(x: down.x + (axis == .horizontal ? delta : 0),
                           y: down.y - (axis == .vertical ? delta : 0))
        try sendPaneMouse(.leftMouseDragged, at: point, to: window)
        try await settle()
        let actual = try divider().firstLength
        print("DIVIDER_TRACKING", axis, delta, actual - initial.firstLength)
        #expect(abs(actual - initial.firstLength - delta) < 2)
    }
    let up = NSPoint(x: down.x - (axis == .horizontal ? 40 : 0), y: down.y + (axis == .vertical ? 40 : 0))
    try sendPaneMouse(.leftMouseUp, at: up, to: window)
    try await settle()
    #expect(abs(try divider().firstLength - initial.firstLength + 40) < 2)
}

// @lat: [[tests#Sidebar visibility animation]]
@Test(.serialized, arguments: [false, true]) @MainActor
func sidebarVisibilityAnimation(animationsDisabled: Bool) async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendSidebarAnimation-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    let page = store.selectedTab.pages[0]
    let controller = store.controller(for: page)
    controller.isStartPage = false
    controller.webView.loadHTMLString("<title>Sidebar animation</title><input value='unsaved'>", baseURL: nil)
    let host = NSHostingView(rootView: BrowserView(store: store)
        .transaction { if animationsDisabled { $0.disablesAnimations = true } }.ignoresSafeArea())
    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1100, height: 700),
                          styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
    window.contentView = host; window.orderFront(nil)
    defer { store.downloads.shutdown(); controller.media.detach(); controller.webView.stopLoading(); window.orderOut(nil); window.contentView = nil }
    func mounted(in view: NSView) -> MountedTabHost? {
        if let view = view as? MountedTabHost { return view }
        return view.subviews.lazy.compactMap { mounted(in: $0) }.first
    }
    for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
    let canvas = try #require(mounted(in: host))
    let originalWebView = controller.webView
    let originalParent = try #require(originalWebView.superview)
    let expanded = canvas.convert(canvas.bounds, to: nil)
    for visible in [false, true] {
        store.sidebarVisible = visible
        var positions: [CGFloat] = []
        for _ in 0..<30 {
            host.layoutSubtreeIfNeeded()
            let frame = canvas.convert(canvas.bounds, to: nil)
            positions.append(frame.minX)
            #expect(abs(frame.maxX - expanded.maxX) < 0.5)
            try await Task.sleep(for: .milliseconds(10))
        }
        let collapsedX = expanded.minX - store.sidebarWidth
        let expected = visible ? expanded.minX : collapsedX
        #expect(abs(positions.last! - expected) < 0.5)
        let intermediate = positions.contains { position in position > collapsedX + 1 && position < expanded.minX - 1 }
        let shouldAnimate = !animationsDisabled && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #expect(intermediate == shouldAnimate)
        #expect(mounted(in: host) === canvas)
        #expect(store.existingController(for: page.id) === controller)
        #expect(controller.webView === originalWebView && originalWebView.superview === originalParent)
        #expect(try await originalWebView.evaluateJavaScript("document.querySelector('input').value") as? String == "unsaved")
    }
    store.sidebarVisible = false
    try await Task.sleep(for: .milliseconds(50))
    store.sidebarVisible = true
    for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
    #expect(abs(canvas.convert(canvas.bounds, to: nil).minX - expanded.minX) < 0.5)
}

// @lat: [[tests#Sidebar resize tracking and restoration]]
@Test @MainActor func sidebarResizeTracking() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseSidebarResize-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("session.json")
    // Missing width remains compatible with sessions from before sidebar resizing.
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try JSONEncoder().encode(BrowserSession()).write(to: file)
    let store = BrowserStore(sessionFile: file, persistentExtensions: false)
    #expect(store.sidebarWidth == 250)
    let host = NSHostingView(rootView: BrowserView(store: store).ignoresSafeArea())
    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1100, height: 800),
        styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.toolbar = NSToolbar(identifier: "SidebarResizeTest")
    window.toolbarStyle = .unified
    window.titlebarAppearsTransparent = true
    window.isMovableByWindowBackground = true
    window.contentView = host
    window.orderFront(nil)
    defer { window.orderOut(nil); window.contentView = nil }
    func settle() async throws {
        for _ in 0..<3 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
    }
    func descendants<T: NSView>(_ type: T.Type, _ view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, $0) }
    }
    try await settle()
    let handle = try #require(descendants(SidebarResizeView.self, host).first)
    let controller = store.controller(for: store.selectedTab.pages[0])
    let pane = try #require(descendants(PaneDropHost.self, host).first)
    let originalPaneWidth = pane.bounds.width
    func drag(_ deltas: [CGFloat]) async throws {
        let startWidth = store.sidebarWidth
        let down = handle.convert(NSPoint(x: 3, y: handle.bounds.midY), to: nil)
        #expect(host.hitTest(host.convert(down, from: nil)) === handle)
        try sendPaneMouse(.leftMouseDown, at: down, to: window)
        for delta in deltas {
            let point = NSPoint(x: down.x + delta, y: down.y)
            try sendPaneMouse(.leftMouseDragged, at: point, to: window)
            try await settle()
            #expect(abs(store.sidebarWidth - min(400, max(200, startWidth + delta))) < 0.5)
        }
        let up = NSPoint(x: down.x + (deltas.last ?? 0), y: down.y)
        try sendPaneMouse(.leftMouseUp, at: up, to: window)
        try await settle()
    }
    try await drag([20, 40, 40, -40, -40, -136, -200, 64, 200, 0, -50])
    #expect(store.sidebarWidth == 200)
    #expect(pane.bounds.width > originalPaneWidth)
    // A second drag must start from the new width, without stale tracking.
    try await drag([20, 20, 100, 100, 50])
    #expect(store.sidebarWidth == 250)
    #expect(store.existingController(for: store.selectedTab.pages[0].id) === controller)
    store.sidebarVisible = false
    try await settle()
    store.sidebarVisible = true
    try await settle()
    #expect(store.sidebarWidth == 250)
    store.resizeSidebar(to: .nan)
    #expect(store.sidebarWidth == 250)
    store.save()
    let restored = BrowserStore(sessionFile: file, persistentExtensions: false)
    #expect(restored.sidebarWidth == 250)
    #expect(restored.session.isValid)
    restored.session.sidebarWidth = 900
    #expect(restored.sidebarWidth == 400)
    restored.session.sidebarWidth = -5
    #expect(restored.sidebarWidth == 200)
    restored.session.sidebarWidth = 236
    #expect(restored.sidebarWidth == 236)
    restored.session.sidebarWidth = .nan
    #expect(restored.sidebarWidth == 250)
}
