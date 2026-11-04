import AppKit
import SwiftUI
import Testing
import BrowseCore
@testable import Browse

// @lat: [[tests#Pane header mouse routing]]
@Test @MainActor func paneHeaderMouseRouting() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseHeaderDrag-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1420, height: 880),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.toolbarStyle = .unified
    window.toolbar = NSToolbar(identifier: "HeaderRoutingTest")
    window.titlebarSeparatorStyle = .none
    window.isMovableByWindowBackground = true
    let content = NSHostingView(rootView: BrowserView(store: store).ignoresSafeArea())
    if #available(macOS 26.0, *) {
        let glass = NSGlassEffectView()
        glass.style = .regular; glass.cornerRadius = 0; glass.contentView = content
        window.contentView = glass
    } else { window.contentView = content }
    window.orderFront(nil)
    defer { window.orderOut(nil); window.contentView = nil }
    for _ in 0..<10 { window.contentView?.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
    func handles(in view: NSView) -> [PaneDragSourceView] {
        (view as? PaneDragSourceView).map { [$0] } ?? view.subviews.flatMap { handles(in: $0) }
    }
    let sources = handles(in: content)
    #expect(sources.count == 4)
    #expect(sources.filter { $0.onHover != nil }.count == 2)
    for source in sources {
        let point = source.convert(NSPoint(x: source.bounds.midX, y: source.bounds.midY), to: nil)
        let frameView = try #require(window.contentView?.superview)
        let hit = frameView.hitTest(frameView.convert(point, from: nil))
        #expect(hit === source)
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        window.sendEvent(down)
        #expect(source.mouseDownPoint == point)
        #expect(store.selectedTab.focusedPane == source.pageID)
        let motion = try #require(NSEvent.mouseEvent(with: .leftMouseDragged,
            location: NSPoint(x: point.x + 2, y: point.y), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 2, clickCount: 1, pressure: 1))
        let originalFrame = window.frame
        window.sendEvent(motion)
        #expect(source.mouseDownPoint == point)
        #expect(window.frame == originalFrame)
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        window.sendEvent(up)
        #expect(source.mouseDownPoint == nil)
    }
}

@MainActor
func sendPaneMouse(_ type: NSEvent.EventType, at point: NSPoint, to window: NSWindow) throws {
    let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
    window.sendEvent(event)
}

// @lat: [[tests#Native pane drop lifecycle]]
@Test @MainActor func nativePaneDropLifecycle() throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseNativeDrop-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    let tab = store.selectedTab
    let source = PaneDragSourceView(frame: NSRect(x: 10, y: 350, width: 150, height: 30))
    source.store = store; source.tabID = tab.id; source.pageID = tab.pages[1].id
    let host = PaneDropHost(frame: NSRect(x: 200, y: 0, width: 600, height: 400))
    host.store = store; host.tabID = tab.id; host.pageID = tab.pages[0].id
    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 800, height: 400),
        styleMask: [.borderless], backing: .buffered, defer: false)
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
    content.addSubview(source); content.addSubview(host)
    window.contentView = content
    window.orderFront(nil)
    defer { source.cancelDrag(); window.orderOut(nil); window.contentView = nil }
    try sendPaneMouse(.leftMouseDown, at: NSPoint(x: 50, y: 365), to: window)
    try sendPaneMouse(.leftMouseDragged, at: NSPoint(x: 500, y: 390), to: window)
    #expect(source.dragSurface?.superview === content)
    #expect(source.dragSurface?.target === host)
    #expect(host.dropEdge == .top)
    #expect(store.selectedTab.layout == tab.layout)
    let preview = try #require(host.layer?.sublayers?.compactMap { $0 as? CAShapeLayer }.first)
    let visibility = PreviewVisibility()
    let observation = preview.observe(\.isHidden, options: [.new]) { _, change in
        MainActor.assumeIsolated { if change.newValue == true { visibility.hiddenTransitions += 1 } }
    }
    // Continuous movement inside one placement region must not hide the layer,
    // even transiently between mouse events or layout passes.
    for x in stride(from: 250.0, through: 700.0, by: 15) {
        try sendPaneMouse(.leftMouseDragged, at: NSPoint(x: x, y: 390), to: window)
        host.layoutSubtreeIfNeeded()
        #expect(host.dropEdge == .top)
        #expect(!preview.isHidden)
    }
    #expect(visibility.hiddenTransitions == 0)
    try sendPaneMouse(.leftMouseDragged, at: NSPoint(x: 500, y: 10), to: window)
    #expect(host.dropEdge == .bottom)
    #expect(visibility.hiddenTransitions == 0)
    observation.invalidate()
    source.cancelOperation(nil)
    #expect(source.dragSurface == nil)
    #expect(host.dropEdge == nil)
    try sendPaneMouse(.leftMouseUp, at: NSPoint(x: 500, y: 10), to: window)
    #expect(store.selectedTab.layout == tab.layout)
    try sendPaneMouse(.leftMouseDown, at: NSPoint(x: 50, y: 365), to: window)
    try sendPaneMouse(.leftMouseDragged, at: NSPoint(x: -5, y: 200), to: window)
    #expect(source.dragSurface?.target == nil)
    try sendPaneMouse(.leftMouseUp, at: NSPoint(x: -5, y: 200), to: window)
    #expect(store.selectedTab.layout == tab.layout)
    try sendPaneMouse(.leftMouseDown, at: NSPoint(x: 50, y: 365), to: window)
    try sendPaneMouse(.leftMouseDragged, at: NSPoint(x: 300, y: 200), to: window)
    #expect(host.dropEdge == .left)
    try sendPaneMouse(.leftMouseUp, at: NSPoint(x: 300, y: 200), to: window)
    #expect(source.dragSurface == nil)
    #expect(host.dropEdge == nil)
    #expect(store.selectedTab.layout.paneIDs == [tab.pages[1].id, tab.pages[0].id])
    #expect(store.selectedTab.focusedPane == tab.pages[1].id)
    #expect(store.session.isValid)
}

@MainActor private final class PreviewVisibility {
    var hiddenTransitions = 0
}

// @lat: [[tests#Pane drop validation and persistence]]
@Test @MainActor func paneDropValidationAndPersistence() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowsePaneDrop-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("session.json")
    let store = BrowserStore(sessionFile: file, persistentExtensions: false)
    let tab = store.selectedTab
    let source = PaneDragSourceView()
    source.store = store; source.tabID = tab.id; source.pageID = tab.pages[1].id
    let host = PaneDropHost(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    host.store = store; host.tabID = tab.id; host.pageID = tab.pages[0].id
    #expect(host.validSource(source) == source.pageID)
    host.isHidden = true
    #expect(host.validSource(source) == nil)
    host.isHidden = false
    store.zoomedPane = tab.focusedPane
    #expect(host.validSource(source) == nil)
    #expect(!store.movePane(tab.pages[1].id, beside: tab.pages[0].id, edge: .top, in: tab.id))
    store.zoomedPane = nil
    #expect(!store.movePane(tab.pages[1].id, beside: tab.pages[0].id, edge: .top, in: UUID()))
    source.pageID = tab.pages[0].id
    #expect(host.validSource(source) == nil)
    source.pageID = UUID()
    #expect(host.validSource(source) == nil)
    source.pageID = tab.pages[1].id
    source.tabID = UUID()
    #expect(host.validSource(source) == nil)
    source.tabID = tab.id
    #expect(store.movePane(tab.pages[1].id, beside: tab.pages[0].id, edge: .top, in: tab.id))
    #expect(store.selectedTab.focusedPane == tab.pages[1].id)
    #expect(store.selectedTab.layout.paneIDs == [tab.pages[1].id, tab.pages[0].id])
    #expect(store.selectedTab.pages.map(\.address) == tab.pages.map(\.address))
    #expect(store.session.isValid)
    #expect(!store.canReopenClosed)
    store.save()
    let restored = BrowserStore(sessionFile: file, persistentExtensions: false)
    #expect(restored.selectedTab.layout == store.selectedTab.layout)
    #expect(restored.selectedTab.focusedPane == store.selectedTab.focusedPane)
    #expect(restored.session.isValid)
}
