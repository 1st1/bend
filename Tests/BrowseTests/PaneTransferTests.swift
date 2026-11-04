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
    window.orderFront(nil)
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

@MainActor private final class DragTrackingWindow: NSWindow {
    var mouseUpCount = 0
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
