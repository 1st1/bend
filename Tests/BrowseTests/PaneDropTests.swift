import AppKit
import SwiftUI
import Testing
import BrowseCore
@testable import Browse

@MainActor private final class ChromeDragTestWindow: BrowseWindow {
    var windowDragRequests = 0
    var forwardingToAppKit = false
    var nativeDragRequests = 0
    override func forwardToAppKit(_ event: NSEvent) {
        forwardingToAppKit = true
        defer { forwardingToAppKit = false }
        super.forwardToAppKit(event)
    }
    override func performDrag(with event: NSEvent) {
        windowDragRequests += 1
        if forwardingToAppKit { nativeDragRequests += 1 }
    }
}

// @lat: [[tests#Pane header mouse routing]]
@Test @MainActor func paneHeaderMouseRouting() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseHeaderDrag-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    let window = ChromeDragTestWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1420, height: 880),
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
    #expect(sources.count == 2)
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
    #expect(window.windowDragRequests == 0)
    func dragAreas(in view: NSView) -> [WindowDragAreaView] {
        (view as? WindowDragAreaView).map { [$0] } ?? view.subviews.flatMap { dragAreas(in: $0) }
    }
    let regions = dragAreas(in: content).filter { !$0.isHiddenOrHasHiddenAncestor }
    let backgrounds = regions.filter { !$0.excluded }
    #expect(backgrounds.count == 3) // sidebar plus both pane headers
    for area in backgrounds {
        let point = area.convert(NSPoint(x: area.bounds.midX, y: area.bounds.midY), to: nil)
        #expect(WindowDragAreaView.find(at: point, in: window) === area)
        let frameView = try #require(window.contentView?.superview)
        // Outside native mouse-down dispatch, the overlay must not claim
        // hit testing (notably scrolling in empty sidebar space).
        #expect(frameView.hitTest(frameView.convert(point, from: nil)) !== area)
        let before = window.windowDragRequests
        try sendPaneMouse(.leftMouseDown, at: point, to: window)
        #expect(window.windowDragRequests == before + 1)
        #expect(window.nativeDragRequests == window.windowDragRequests)
        #expect(!window.capturesPaneGesture)
        try sendPaneMouse(.leftMouseUp, at: point, to: window)
    }
    for area in regions where area.excluded {
        let point = area.convert(NSPoint(x: area.bounds.midX, y: area.bounds.midY), to: nil)
        #expect(WindowDragAreaView.find(at: point, in: window) == nil)
    }
    for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
        let button = try #require(window.standardWindowButton(kind))
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        #expect(WindowDragAreaView.find(at: point, in: window) == nil)
    }
    func clickSidebarButton(x: CGFloat) async throws {
        let y = content.isFlipped ? content.bounds.minY + 23.5 : content.bounds.maxY - 23.5
        let point = content.convert(NSPoint(x: x, y: y), to: nil)
        let frame = try #require(window.contentView?.superview)
        #expect(!(frame.hitTest(frame.convert(point, from: nil)) is NSScrollView))
        try sendPaneMouse(.leftMouseDown, at: point, to: window)
        try sendPaneMouse(.leftMouseUp, at: point, to: window)
        try await Task.sleep(for: .milliseconds(150))
    }
    let tabsBefore = store.session.workspaces.flatMap(\.tabs).count
    try await clickSidebarButton(x: store.sidebarWidth - 59)
    #expect(store.session.workspaces.flatMap(\.tabs).count == tabsBefore + 1)
    try await clickSidebarButton(x: store.sidebarWidth - 29)
    #expect(!store.sidebarVisible)
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
    let window = BrowseWindow(contentRect: NSRect(x: -10000, y: -10000, width: 800, height: 400),
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
    // SwiftUI can retire a representable before AppKit removes its cached view.
    // Teardown must clear tracking immediately, and the visual surface must
    // never become a full-window input shield, even while a drag is active.
    try sendPaneMouse(.leftMouseDown, at: NSPoint(x: 50, y: 365), to: window)
    try sendPaneMouse(.leftMouseDragged, at: NSPoint(x: 300, y: 200), to: window)
    let activeSurface = try #require(source.dragSurface)
    #expect(content.hitTest(NSPoint(x: 500, y: 200)) === host)
    PaneDragHandle.dismantleNSView(source, coordinator: ())
    #expect(window.activePaneDrag == nil)
    #expect(window.capturesPaneGesture)
    #expect(source.dragSurface == nil)
    #expect(source.mouseDownPoint == nil)
    #expect(activeSurface.superview == nil)
    #expect(host.dropEdge == nil)
    try sendPaneMouse(.leftMouseUp, at: NSPoint(x: 300, y: 200), to: window)
    #expect(!window.capturesPaneGesture)
    try sendPaneMouse(.leftMouseDown, at: NSPoint(x: 50, y: 365), to: window)
    try sendPaneMouse(.leftMouseDragged, at: NSPoint(x: 500, y: 390), to: window)
    #expect(source.dragSurface?.target === host)
    try sendPaneMouse(.leftMouseUp, at: NSPoint(x: 500, y: 390), to: window)
    #expect(source.dragSurface == nil)
    // Window deactivation cancels the session but still owns its trailing up.
    try sendPaneMouse(.leftMouseDown, at: NSPoint(x: 50, y: 365), to: window)
    try sendPaneMouse(.leftMouseDragged, at: NSPoint(x: 300, y: 200), to: window)
    window.resignKey()
    #expect(source.dragSurface == nil)
    #expect(window.activePaneDrag == nil)
    #expect(window.capturesPaneGesture)
    try sendPaneMouse(.leftMouseUp, at: NSPoint(x: 300, y: 200), to: window)
    #expect(!window.capturesPaneGesture)
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
