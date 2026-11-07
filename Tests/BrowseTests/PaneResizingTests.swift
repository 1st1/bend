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
    #expect(store.sidebarWidth == 236)
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
            #expect(abs(store.sidebarWidth - min(300, max(100, startWidth + delta))) < 0.5)
        }
        let up = NSPoint(x: down.x + (deltas.last ?? 0), y: down.y)
        try sendPaneMouse(.leftMouseUp, at: up, to: window)
        try await settle()
    }
    try await drag([20, 40, 40, -40, -40, -136, -200, 64, 200, 0, -36])
    #expect(store.sidebarWidth == 200)
    #expect(pane.bounds.width > originalPaneWidth)
    // A second drag must start from the new width, without stale tracking.
    try await drag([20, 20, -50])
    #expect(store.sidebarWidth == 150)
    #expect(store.existingController(for: store.selectedTab.pages[0].id) === controller)
    store.sidebarVisible = false
    try await settle()
    store.sidebarVisible = true
    try await settle()
    #expect(store.sidebarWidth == 150)
    store.resizeSidebar(to: .nan)
    #expect(store.sidebarWidth == 150)
    store.save()
    let restored = BrowserStore(sessionFile: file, persistentExtensions: false)
    #expect(restored.sidebarWidth == 150)
    #expect(restored.session.isValid)
    restored.session.sidebarWidth = 900
    #expect(restored.sidebarWidth == 300)
    restored.session.sidebarWidth = -5
    #expect(restored.sidebarWidth == 100)
}
