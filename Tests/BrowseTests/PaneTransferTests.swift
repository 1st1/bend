import AppKit
import SwiftUI
import Testing
import WebKit
import BrowseCore
@testable import Browse

// @lat: [[tests#Cross-tab native pane dragging]]
@Test @MainActor func crossTabPaneDragging() async throws {
    guard #available(macOS 15.4, *) else { return }
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseTransfer-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let server = try await ExtensionHTTPFixture.start()
    defer { server.listener.cancel() }
    let address = "http://127.0.0.1:\(server.port)/"
    let manager = ExtensionManager(root: root.appendingPathComponent("extensions"), persistent: false,
        websiteDataStore: .nonPersistent(), notifications: TestNotifications())
    manager.presentsWindows = false
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), extensionManager: manager)
    let first = BrowserTab(pages: [Page(address: address)]), second = BrowserTab(pages: [Page(address: address)])
    let workspace = Workspace(name: "Test", tabs: [first, second])
    store.session.workspaces = [workspace]
    store.session.selectedTab = first.id
    let window = DragTrackingWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1400, height: 850),
        styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.toolbarStyle = .unified
    window.toolbar = NSToolbar(identifier: "TransferTest")
    window.isMovableByWindowBackground = true
    let content = NSHostingView(rootView: BrowserView(store: store).ignoresSafeArea())
    if #available(macOS 26.0, *) {
        let glass = NSGlassEffectView()
        glass.style = .regular; glass.cornerRadius = 0; glass.contentView = content
        window.contentView = glass
    } else { window.contentView = content }
    window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil); window.contentView = nil }
    func settle(_ count: Int = 6) async throws {
        for _ in 0..<count { content.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(50)) }
    }
    func descendants<T: NSView>(_ type: T.Type, _ view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, $0) }
    }
    func handle(_ page: UUID) throws -> PaneDragSourceView {
        try #require(descendants(PaneDragSourceView.self, content).first { $0.pageID == page && $0.onHover != nil && !$0.isHiddenOrHasHiddenAncestor })
    }
    func center(_ view: NSView) -> NSPoint { view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil) }
    try await settle()
    let pageID = first.pages[0].id
    let controller = try #require(store.existingController(for: pageID))
    let web = controller.webView
    for _ in 0..<40 {
        if (try? await web.evaluateJavaScript("document.body?.textContent.includes('Fixture')")) as? Bool == true { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    let stamp = try await web.evaluateJavaScript("performance.timeOrigin") as? Double
    _ = try await web.evaluateJavaScript("document.body.innerHTML='<input id=transfer value=retained>'; window.transferToken='alive'")
    let adapter = try #require(manager.tabs[pageID])
    #expect(store.existingController(for: second.pages[0].id) == nil)
    let source = try handle(pageID)
    let row = try #require(descendants(PaneSidebarTargetView.self, content).first { $0.destination == .tab(second.id) })
    // Leaving a row or cancelling before the hover delay must not switch tabs.
    try sendTransferMouse(.leftMouseDown, at: center(source), to: window)
    try sendTransferMouse(.leftMouseDragged, at: center(row), to: window)
    #expect(source.dragSurface?.sidebarTarget?.destination == row.destination)
    source.cancelOperation(nil)
    try await settle(10)
    #expect(store.session.selectedTab == first.id)
    #expect(store.selectedTab.pages.count == 1)
    try sendTransferMouse(.leftMouseUp, at: center(row), to: window)
    // Hover an unvisited destination, then drop on its actual WebKit content.
    try sendTransferMouse(.leftMouseDown, at: center(source), to: window)
    try sendTransferMouse(.leftMouseDragged, at: center(row), to: window)
    try await settle(12)
    #expect(store.session.selectedTab == second.id)
    #expect(source.dragSurface != nil)
    let destinationWeb = try #require(store.existingController(for: second.pages[0].id)?.webView)
    let point = destinationWeb.convert(NSPoint(x: destinationWeb.bounds.width * 0.9, y: destinationWeb.bounds.midY), to: nil)
    try sendTransferMouse(.leftMouseDragged, at: point, to: window)
    #expect(source.dragSurface?.target?.pageID == second.pages[0].id)
    #expect(source.dragSurface?.target?.dropEdge == .right)
    let firstReleaseCount = window.mouseUpCount
    try sendTransferMouse(.leftMouseUp, at: point, to: window)
    #expect(window.mouseUpCount == firstReleaseCount + 1)
    try await settle()
    #expect(source.dragSurface == nil)
    #expect(store.selectedTab.layout.paneIDs == [second.pages[0].id, pageID])
    #expect(!store.session.workspaces.flatMap(\.tabs).contains { $0.id == first.id })
    #expect(store.existingController(for: pageID) === controller)
    #expect(controller.webView === web)
    #expect(web.window === window && !web.isHiddenOrHasHiddenAncestor)
    #expect(try await web.evaluateJavaScript("performance.timeOrigin") as? Double == stamp)
    #expect(try await web.evaluateJavaScript("document.querySelector('#transfer').value") as? String == "retained")
    #expect(manager.tabs[pageID] === adapter)
    #expect(!store.canReopenClosed)
    // Reuse the same retained header through several same-tab drops. Unlike a
    // transfer, these don't replace its native mouse-tracking view.
    for (draggedID, edge) in [(pageID, PaneDropEdge.top), (second.pages[0].id, .left), (pageID, .bottom), (second.pages[0].id, .right)] {
        let repeatedSource = try handle(draggedID)
        let targetID = draggedID == pageID ? second.pages[0].id : pageID
        let targetWeb = draggedID == pageID ? destinationWeb : web
        let down = center(repeatedSource)
        let enter = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: down, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, trackingNumber: 1, userData: nil))
        repeatedSource.mouseEntered(with: enter)
        try await Task.sleep(for: .milliseconds(35))
        content.layoutSubtreeIfNeeded()
        let frameView = try #require(window.contentView?.superview)
        #expect(frameView.hitTest(frameView.convert(down, from: nil)) === repeatedSource)
        let pointInPage: NSPoint
        switch edge {
        case .top: pointInPage = NSPoint(x: targetWeb.bounds.midX, y: targetWeb.isFlipped ? 40 : targetWeb.bounds.height - 40)
        case .bottom: pointInPage = NSPoint(x: targetWeb.bounds.midX, y: targetWeb.isFlipped ? targetWeb.bounds.height - 40 : 40)
        case .left: pointInPage = NSPoint(x: 40, y: targetWeb.bounds.midY)
        case .right: pointInPage = NSPoint(x: targetWeb.bounds.width - 40, y: targetWeb.bounds.midY)
        }
        let drop = targetWeb.convert(pointInPage, to: nil)
        try sendTransferMouse(.leftMouseDown, at: down, to: window)
        try await settle(2)
        #expect(repeatedSource.mouseDownPoint == down)
        try sendTransferMouse(.leftMouseDragged, at: drop, to: window)
        #expect(repeatedSource.dragSurface?.target?.pageID == targetID)
        #expect(repeatedSource.dragSurface?.target?.dropEdge == edge)
        let releaseCount = window.mouseUpCount
        try sendTransferMouse(.leftMouseUp, at: drop, to: window)
        #expect(window.mouseUpCount == releaseCount + 1)
        try await settle()
        #expect(repeatedSource.dragSurface == nil)
        #expect(repeatedSource.mouseDownPoint == nil)
        #expect(store.selectedTab.layout.paneIDs == (edge.isBefore ? [draggedID, targetID] : [targetID, draggedID]))
    }
    // If a release is lost, the next press must reach a different pane and
    // start a new gesture instead of being swallowed by the old overlay.
    let abandoned = try handle(pageID)
    let replacement = try handle(second.pages[0].id)
    try sendTransferMouse(.leftMouseDown, at: center(abandoned), to: window)
    try sendTransferMouse(.leftMouseDragged, at: center(replacement), to: window)
    let abandonedSurface = try #require(abandoned.dragSurface)
    try sendTransferMouse(.leftMouseDown, at: center(replacement), to: window)
    #expect(abandoned.dragSurface == nil)
    #expect(abandonedSurface.superview == nil)
    #expect(replacement.mouseDownPoint != nil)
    let recoveryDrop = web.convert(NSPoint(x: 40, y: web.bounds.midY), to: nil)
    try sendTransferMouse(.leftMouseDragged, at: recoveryDrop, to: window)
    #expect(replacement.dragSurface?.target?.pageID == pageID)
    try sendTransferMouse(.leftMouseUp, at: recoveryDrop, to: window)
    try await settle()
    #expect(replacement.dragSurface == nil)
    #expect(store.selectedTab.layout.paneIDs == [second.pages[0].id, pageID])

    // Drag back into unused sidebar space to create a tab with the same page.
    let moved = try handle(pageID)
    try sendTransferMouse(.leftMouseDown, at: center(moved), to: window)
    let sidebarPoint = NSPoint(x: 100, y: 100)
    try sendTransferMouse(.leftMouseDragged, at: sidebarPoint, to: window)
    #expect(moved.dragSurface?.sidebarTarget?.destination == .workspace(workspace.id))
    try sendTransferMouse(.leftMouseUp, at: sidebarPoint, to: window)
    try await settle()
    #expect(store.selectedTab.id != second.id)
    #expect(store.selectedTab.pages.map(\.id) == [pageID])
    #expect(store.existingController(for: pageID) === controller)
    #expect(try await web.evaluateJavaScript("window.transferToken") as? String == "alive")
    #expect(try await web.evaluateJavaScript("performance.timeOrigin") as? Double == stamp)
    #expect(manager.tabs[pageID] === adapter)
    #expect(store.session.isValid)
    #expect(!store.canReopenClosed)
    // A direct drop on a row also works before the delayed tab switch fires.
    let detachedID = store.selectedTab.id
    let detachedHandle = try handle(pageID)
    let destinationRow = try #require(descendants(PaneSidebarTargetView.self, content).first { $0.destination == .tab(second.id) })
    try sendTransferMouse(.leftMouseDown, at: center(detachedHandle), to: window)
    try sendTransferMouse(.leftMouseDragged, at: center(destinationRow), to: window)
    try sendTransferMouse(.leftMouseUp, at: center(destinationRow), to: window)
    try await settle(10)
    #expect(store.selectedTab.id == second.id)
    #expect(store.selectedTab.layout.paneIDs == [second.pages[0].id, pageID])
    #expect(!store.session.workspaces.flatMap(\.tabs).contains { $0.id == detachedID })
    #expect(try await web.evaluateJavaScript("performance.timeOrigin") as? Double == stamp)
    #expect(try await web.evaluateJavaScript("document.querySelector('#transfer').value") as? String == "retained")
    #expect(!store.canReopenClosed)
    store.save()
    let saved = try JSONDecoder().decode(BrowserSession.self, from: Data(contentsOf: root.appendingPathComponent("session.json")))
    #expect(saved.isValid)
    #expect(saved.selectedTab == store.selectedTab.id)
}

@MainActor private final class DragTrackingWindow: BrowseWindow {
    var mouseUpCount = 0
    var forwardedMouseEvents = 0
    override func forwardToAppKit(_ event: NSEvent) {
        if [.leftMouseDown, .leftMouseDragged, .leftMouseUp].contains(event.type) { forwardedMouseEvents += 1 }
        super.forwardToAppKit(event)
    }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseUp { mouseUpCount += 1 }
        super.sendEvent(event)
    }
}

@MainActor private func sendTransferMouse(_ type: NSEvent.EventType, at point: NSPoint, to window: NSWindow) throws {
    let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
    NSApplication.shared.sendEvent(event)
}

// @lat: [[tests#Native sidebar tab dragging]]
@Test @MainActor func nativeSidebarTabDragging() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseTabDrag-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    let tabs = [BrowserTab(title: "First"), BrowserTab(title: "Second"), BrowserTab(title: "Third")]
    store.session.workspaces = [Workspace(name: "Tabs", tabs: tabs)]
    store.session.selectedTab = tabs[1].id
    let window = DragTrackingWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1100, height: 800),
        styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
    window.toolbarStyle = .unified; window.toolbar = NSToolbar(identifier: "TabReorderTest")
    window.isMovableByWindowBackground = true
    let host = NSHostingView(rootView: BrowserView(store: store).ignoresSafeArea())
    if #available(macOS 26.0, *) {
        let glass = NSGlassEffectView(); glass.style = .regular; glass.contentView = host
        window.contentView = glass
    } else { window.contentView = host }
    window.orderFront(nil)
    defer { window.orderOut(nil); window.contentView = nil }
    func settle() async throws {
        for _ in 0..<3 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(50)) }
    }
    func descendants<T: NSView>(_ type: T.Type, _ view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, $0) }
    }
    func row(_ id: UUID) throws -> PaneSidebarTargetView {
        try #require(descendants(PaneSidebarTargetView.self, host).first { $0.destination == .tab(id) })
    }
    func point(_ id: UUID, below: Bool = false) throws -> NSPoint {
        let row = try row(id)
        let y = below ? (row.isFlipped ? row.bounds.maxY - 3 : row.bounds.minY + 3) : row.bounds.midY
        return row.convert(NSPoint(x: 60, y: y), to: nil)
    }
    try await settle()
    let frame = window.frame
    let down = try point(tabs[0].id)
    let up = try point(tabs[2].id, below: true)
    try sendTransferMouse(.leftMouseDown, at: down, to: window)
    try sendTransferMouse(.leftMouseDragged, at: up, to: window)
    try await settle()
    #expect(store.session.workspaces[0].tabs.map(\.id) == tabs.map(\.id))
    let releases = window.mouseUpCount
    try sendTransferMouse(.leftMouseUp, at: up, to: window)
    try await settle()
    #expect(store.session.workspaces[0].tabs.map(\.id) == [tabs[1].id, tabs[2].id, tabs[0].id])
    #expect(store.session.selectedTab == tabs[1].id)
    #expect(window.mouseUpCount == releases + 1)
    #expect(window.frame == frame)
    let source = try #require(descendants(TabDragSourceView.self, host).first { $0.tabID == tabs[0].id })
    #expect(source.mouseDownPoint == nil)
    #expect(source.dragSurface == nil)
    // Repeat in the opposite direction using the same native source view.
    let firstRow = try row(tabs[1].id)
    let above = firstRow.convert(NSPoint(x: 60, y: firstRow.isFlipped ? 3 : firstRow.bounds.height - 3), to: nil)
    let secondDown = try point(tabs[0].id)
    try sendTransferMouse(.leftMouseDown, at: secondDown, to: window)
    for offset in [0.0, 2, 4, 2, 0] {
        try sendTransferMouse(.leftMouseDragged, at: NSPoint(x: above.x + offset, y: above.y), to: window)
        #expect(source.dragSurface?.placement == .init(tabID: tabs[1].id, after: false))
    }
    try sendTransferMouse(.leftMouseUp, at: above, to: window)
    try await settle()
    #expect(store.session.workspaces[0].tabs.map(\.id) == tabs.map(\.id))
    #expect(store.session.selectedTab == tabs[1].id)
    #expect(source.dragSurface == nil)
    // Escape and releasing outside the sidebar leave the order unchanged.
    for cancel in [true, false] {
        try sendTransferMouse(.leftMouseDown, at: try point(tabs[0].id), to: window)
        try sendTransferMouse(.leftMouseDragged, at: try point(tabs[2].id, below: true), to: window)
        #expect(source.dragSurface != nil)
        if cancel {
            let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            NSApplication.shared.sendEvent(escape)
            #expect(source.dragSurface == nil)
        }
        let outside = NSPoint(x: 600, y: 300)
        try sendTransferMouse(.leftMouseDragged, at: outside, to: window)
        #expect(source.dragSurface?.placement == nil)
        try sendTransferMouse(.leftMouseUp, at: outside, to: window)
        try await settle()
        #expect(source.dragSurface == nil)
        #expect(store.session.workspaces[0].tabs.map(\.id) == tabs.map(\.id))
        #expect(store.session.selectedTab == tabs[1].id)
    }
    // Tab overlays also cannot block the next click when a release is lost.
    try sendTransferMouse(.leftMouseDown, at: try point(tabs[0].id), to: window)
    try sendTransferMouse(.leftMouseDragged, at: try point(tabs[2].id), to: window)
    #expect(source.dragSurface != nil)
    // Plain clicks still select; close controls stay outside the drag handle.
    let click = try point(tabs[2].id)
    try sendTransferMouse(.leftMouseDown, at: click, to: window)
    try sendTransferMouse(.leftMouseDragged, at: NSPoint(x: click.x + 2, y: click.y), to: window)
    try sendTransferMouse(.leftMouseUp, at: click, to: window)
    try await settle()
    #expect(store.session.selectedTab == tabs[2].id)
    #expect(source.dragSurface == nil)
    let closeRow = try row(tabs[2].id)
    let close = closeRow.convert(NSPoint(x: closeRow.bounds.width - 19, y: closeRow.bounds.midY), to: nil)
    #expect(!(host.hitTest(host.convert(close, from: nil)) is TabDragSourceView))
    try sendTransferMouse(.leftMouseDown, at: close, to: window)
    try sendTransferMouse(.leftMouseUp, at: close, to: window)
    try await settle()
    #expect(store.session.workspaces[0].tabs.map(\.id) == [tabs[0].id, tabs[1].id])
    #expect(window.frame == frame)
}

// @lat: [[tests#Pane transfer round trips]]
@Test(.serialized, arguments: [false, true]) @MainActor func paneTransferRoundTrips(crowded: Bool) async throws {
    guard #available(macOS 15.4, *) else { return }
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseRoundTrip-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let server = try await ExtensionHTTPFixture.start()
    defer { server.listener.cancel() }
    let address = "http://127.0.0.1:\(server.port)/"
    let manager = ExtensionManager(root: root.appendingPathComponent("extensions"), persistent: false,
        websiteDataStore: .nonPersistent(), notifications: TestNotifications())
    manager.presentsWindows = false
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), extensionManager: manager)
    let moving = Page(address: address), anchorA = Page(address: address), anchorB = Page(address: address)
    let first = BrowserTab(pages: crowded ? [moving, Page(address: address), anchorA] : [anchorA, moving])
    let second = BrowserTab(pages: [anchorB])
    store.session.workspaces = [Workspace(name: "Test", tabs: [first, second])]
    store.session.selectedTab = first.id
    let window = DragTrackingWindow(contentRect: NSRect(x: -10000, y: -10000, width: crowded ? 1100 : 1400, height: 850),
        styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
    window.toolbarStyle = .unified; window.toolbar = NSToolbar(identifier: "RoundTripTest")
    window.isMovableByWindowBackground = true
    let content = NSHostingView(rootView: BrowserView(store: store).ignoresSafeArea())
    if #available(macOS 26.0, *) {
        let glass = NSGlassEffectView(); glass.style = .regular; glass.contentView = content
        window.contentView = glass
    } else { window.contentView = content }
    window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil); window.contentView = nil }
    func settle(_ count: Int = 6) async throws {
        for _ in 0..<count { content.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(50)) }
    }
    func descendants<T: NSView>(_ type: T.Type, _ view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, $0) }
    }
    func center(_ view: NSView) -> NSPoint { view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil) }
    try await settle()
    let controller = try #require(store.existingController(for: moving.id))
    let web = controller.webView
    for _ in 0..<40 {
        if (try? await web.evaluateJavaScript("document.body?.textContent.includes('Fixture')")) as? Bool == true { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    _ = try await web.evaluateJavaScript("window.roundTripToken='retained'; document.body.innerHTML='<input id=draft value=unsaved>'")
    let initialOrigin = try await web.evaluateJavaScript("performance.timeOrigin")
    let stamp = try #require(initialOrigin as? Double)
    window.makeFirstResponder(web)
    for index in 0..<24 {
        let destination = index.isMultiple(of: 2) ? second.id : first.id
        let anchor = index.isMultiple(of: 2) ? anchorB.id : anchorA.id
        let handles = descendants(PaneDragSourceView.self, content).filter {
            $0.pageID == moving.id && $0.onHover != nil && !$0.isHiddenOrHasHiddenAncestor
        }
        #expect(handles.count == 1, "Round trip gesture \(index + 1): exactly one visible title handle")
        let source = try #require(handles.first)
        #expect(source.tabID == store.selectedTab.id)
        let down = center(source)
        let frameView = try #require(window.contentView?.superview)
        #expect(frameView.hitTest(frameView.convert(down, from: nil)) === source)
        let forwarded = window.forwardedMouseEvents
        try sendTransferMouse(.leftMouseDown, at: down, to: window)
        #expect(window.activePaneDrag === source)
        #expect(source.mouseDownPoint != nil, "Round trip gesture \(index + 1): press reaches handle")
        let row = try #require(descendants(PaneSidebarTargetView.self, content).first { $0.destination == .tab(destination) })
        try sendTransferMouse(.leftMouseDragged, at: center(row), to: window)
        #expect(source.dragSurface != nil, "Round trip gesture \(index + 1): drag starts")
        if index < 20 {
            // The original tabs both survive; hover mounts their retained trees.
            try await settle(12)
            #expect(store.selectedTab.id == destination)
            let target = try #require(store.existingController(for: anchor)?.webView)
            target.scrollToVisible(target.bounds)
            try await settle(2)
            let visible = target.bounds.intersection(target.visibleRect)
            let drop = target.convert(NSPoint(x: visible.maxX - 40, y: visible.midY), to: nil)
            try sendTransferMouse(.leftMouseDragged, at: drop, to: window)
            #expect(source.dragSurface?.target?.pageID == anchor)
            try sendTransferMouse(.leftMouseUp, at: drop, to: window)
        } else {
            try sendTransferMouse(.leftMouseUp, at: center(row), to: window)
        }
        try await settle()
        #expect(source.dragSurface == nil)
        #expect(source.mouseDownPoint == nil)
        #expect(store.selectedTab.id == destination)
        #expect(store.selectedTab.pages.contains { $0.id == moving.id })
        #expect(window.activePaneDrag == nil)
        #expect(!window.capturesPaneGesture)
        #expect(window.forwardedMouseEvents == forwarded, "The complete pane gesture bypasses AppKit view tracking")
        #expect(store.session.workspaces[0].tabs.count == 2)
        #expect(store.session.workspaces.flatMap(\.tabs).flatMap(\.pages).filter { $0.id == moving.id }.count == 1)
        #expect(store.existingController(for: moving.id) === controller)
        #expect(web.window === window && !web.isHiddenOrHasHiddenAncestor)
        #expect(try await web.evaluateJavaScript("window.roundTripToken") as? String == "retained")
        let currentOrigin = try await web.evaluateJavaScript("performance.timeOrigin")
        let actualStamp = try #require(currentOrigin as? Double)
        // WebKit can quantize this timestamp to adjacent millisecond buckets.
        // The token and unsaved DOM input above/below prove document identity.
        #expect(abs(actualStamp - stamp) <= 2)
        #expect(try await web.evaluateJavaScript("document.querySelector('#draft').value") as? String == "unsaved")
        #expect(descendants(PaneDragSurface.self, window.contentView!).isEmpty)
        #expect(!store.canReopenClosed)
        window.makeFirstResponder(web)
    }
}
