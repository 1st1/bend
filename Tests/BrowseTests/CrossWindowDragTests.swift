import AppKit
import BrowseCore
import Testing
import WebKit
@testable import Browse

@Suite(.serialized) struct CrossWindowDragTests {
// @lat: [[tests#Cross-window live transfers]]
@Test @MainActor func crossWindowLiveTransfers() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendWindowTransfer-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let owner = BrowserWindows(root: root, persistentExtensions: false)
    owner.restore(show: false)
    let first = try #require(owner.active), second = owner.newWindow(show: false)
    defer { owner.prepareToQuit(); for context in owner.windows { context.window.close() } }
    let source = first.store, destination = second.store
    var tab = BrowserTab(title: "Moving", pages: [Page(), Page()])
    tab.commandClickPaneID = tab.pages[1].id
    let anchor = BrowserTab()
    source.session.workspaces = [Workspace(name: "Tabs", tabs: [tab, anchor])]
    source.session.selectedTab = tab.id
    let originalDestination = destination.selectedTab
    let pages = tab.pages.map { source.controller(for: $0) }
    for page in pages {
        page.webView.loadHTMLString("<input value='unsaved'><script>window.token='alive'</script>", baseURL: nil)
        for _ in 0..<50 {
            if (try? await page.webView.evaluateJavaScript("window.token")) as? String == "alive" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    pages[0].webView.pageZoom = 1.25
    pages[0].webView.magnification = 2
    source.saveSoon()
    #expect(source.transfer(tab: tab.id, to: destination, at: .insert(relativeTo: originalDestination.id, after: false)))
    #expect(source.session.isValid && destination.session.isValid)
    #expect(owner.windows.count == 2)
    #expect(source.selectedTab.id == anchor.id)
    #expect(source.selectedTab.pages.count == 1)
    #expect(source.selectedTab.pages[0].address == "browse://start")
    #expect(destination.selectedTab.id == tab.id)
    #expect(destination.selectedTab.layout == tab.layout)
    #expect(destination.selectedTab.commandClickPaneID == tab.commandClickPaneID)
    for (model, page) in zip(tab.pages, pages) {
        #expect(source.existingController(for: model.id) == nil)
        #expect(destination.existingController(for: model.id) === page)
        if #available(macOS 15.4, *) {
            #expect(source.extensions.tabs[model.id]?.store === destination)
            #expect(source.extensions.tabs[model.id]?.pageController === page)
        }
        #expect(try await page.webView.evaluateJavaScript("window.token") as? String == "alive")
    }
    // Navigation and new-link callbacks must now update the destination store.
    pages[0].onNavigation?("https://example.com/moved", "Moved title")
    #expect(destination.selectedTab.pages[0].address == "https://example.com/moved")
    #expect(source.selectedTab.pages[0].address == "browse://start")
    pages[0].onNewPane?("browse://guide")
    #expect(destination.selectedTab.pages.count == 3)
    #expect(source.selectedTab.pages.count == 1)
    let sourceTab = source.selectedTab
    // Repeated cross-window pane moves keep the same document and adapter.
    for _ in 0..<3 {
        #expect(destination.transfer(tab: tab.id, pane: tab.pages[0].id, to: source,
                                     at: .join(tab: sourceTab.id, pane: sourceTab.focusedPane, edge: .left)))
        #expect(source.transfer(tab: sourceTab.id, pane: tab.pages[0].id, to: destination,
                                at: .join(tab: tab.id, pane: tab.pages[1].id, edge: .bottom)))
        #expect(destination.existingController(for: tab.pages[0].id) === pages[0])
        #expect(pages[0].webView.pageZoom == 1.25)
        #expect(pages[0].webView.magnification == 2)
        #expect(try await pages[0].webView.evaluateJavaScript("document.querySelector('input').value") as? String == "unsaved")
    }
    let count = destination.selectedTab.pages.count
    #expect(!destination.transfer(tab: tab.id, pane: UUID(), to: source, at: .workspace(source.session.workspaces[0].id)))
    #expect(!destination.transfer(tab: tab.id, to: source, at: .join(tab: UUID(), pane: nil, edge: .right)))
    #expect(destination.selectedTab.pages.count == count)
    #expect(!source.canReopenClosed && !destination.canReopenClosed)
    #expect(source.session.isValid && destination.session.isValid)
    owner.save()
    let saved = try JSONDecoder().decode(BrowserSession.self, from: Data(contentsOf: root.appendingPathComponent("Windows/\(second.id).json")))
    #expect(saved.isValid && saved.selectedTab == tab.id)
    first.window.close()
    #expect(destination.existingController(for: tab.pages[0].id) === pages[0])
    #expect(try await pages[0].webView.evaluateJavaScript("window.token") as? String == "alive")
}

// @lat: [[tests#Cross-window drag gestures]]
@Test @MainActor func crossWindowDragGestures() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendWindowGestures-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let owner = BrowserWindows(root: root, persistentExtensions: false)
    owner.restore(show: false)
    let first = try #require(owner.active), second = owner.newWindow(show: false)
    defer { owner.prepareToQuit(); for context in owner.windows { context.window.close() } }
    let server = try await ExtensionHTTPFixture.start()
    defer { server.listener.cancel() }
    let address = "http://127.0.0.1:\(server.port)/"
    for context in [first, second] {
        let tab = BrowserTab(pages: context === first ? [Page(address: address), Page(address: address)] : [Page(address: address)])
        context.store.session.workspaces = [Workspace(name: "Tabs", tabs: [tab])]
        context.store.session.selectedTab = tab.id
    }
    for (index, context) in [first, second].enumerated() {
        context.window.setFrame(NSRect(x: 0, y: 0, width: 1400, height: 850), display: true)
        context.window.makeKeyAndOrderFront(nil)
        context.window.setFrameOrigin(NSPoint(x: -1300 + index * 1400, y: -700))
    }
    first.window.makeKeyAndOrderFront(nil)
    first.window.setFrameOrigin(NSPoint(x: -1300, y: -700))
    func settle() async throws {
        for _ in 0..<8 {
            first.window.contentView?.layoutSubtreeIfNeeded(); second.window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
    }
    func descendants<T: NSView>(_ type: T.Type, _ view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, $0) }
    }
    func point(_ view: NSView, in window: NSWindow, fraction: CGFloat = 0.5) -> NSPoint {
        let local = view.convert(NSPoint(x: view.bounds.width * fraction, y: view.bounds.midY), to: nil)
        return window.convertPoint(fromScreen: view.window!.convertPoint(toScreen: local))
    }
    func event(_ type: NSEvent.EventType, _ point: NSPoint, _ window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
    }
    try await settle()
    let original = first.store.selectedTab
    let moving = original.pages[0].id
    let controller = try #require(first.store.existingController(for: moving))
    let targetID = second.store.selectedTab.focusedPane
    let handle = try #require(descendants(PaneDragSourceView.self, first.window.contentView!).first {
        $0.pageID == moving && $0.onHover != nil && !$0.isHiddenOrHasHiddenAncestor
    })
    let target = try #require(descendants(PaneDropHost.self, second.window.contentView!).first { $0.pageID == targetID })
    let down = point(handle, in: first.window), drop = point(target, in: first.window, fraction: 0.9)
    first.window.sendEvent(try event(.leftMouseDown, down, first.window))
    let keyDuringPaneDrag = NSApp.keyWindow
    first.window.sendEvent(try event(.leftMouseDragged, drop, first.window))
    #expect(handle.dragSurface?.target?.pageID == targetID)
    #expect(handle.dragSurface?.window === second.window)
    #expect(NSApp.orderedWindows.first { $0 is BrowseWindow } === second.window)
    #expect(NSApp.keyWindow === keyDuringPaneDrag)
    #expect(first.window.activePaneDrag === handle)
    // Escape clears the destination overlay without moving either model.
    handle.cancelOperation(nil)
    first.window.sendEvent(try event(.leftMouseUp, drop, first.window))
    #expect(first.store.selectedTab.pages.contains { $0.id == moving })
    #expect(descendants(PaneDragSurface.self, second.window.contentView!).isEmpty)
    first.window.sendEvent(try event(.leftMouseDown, down, first.window))
    first.window.sendEvent(try event(.leftMouseDragged, drop, first.window))
    first.window.sendEvent(try event(.leftMouseUp, drop, first.window))
    try await settle()
    #expect(second.store.existingController(for: moving) === controller)
    #expect(first.store.existingController(for: moving) == nil)
    #expect(controller.webView.window === second.window)
    #expect(second.store.selectedTab.pages.contains { $0.id == moving })
    #expect(!first.window.capturesPaneGesture)
    // Move the entire destination tab back using its sidebar insertion band.
    let tabID = second.store.selectedTab.id
    let tabHandle = try #require(descendants(TabDragSourceView.self, second.window.contentView!).first { $0.tabID == tabID })
    let row = try #require(descendants(PaneSidebarTargetView.self, first.window.contentView!).first { $0.destination == .tab(original.id) })
    let rowLocal = row.convert(NSPoint(x: row.bounds.midX, y: row.isFlipped ? 1 : row.bounds.height - 1), to: nil)
    let tabDrop = second.window.convertPoint(fromScreen: first.window.convertPoint(toScreen: rowLocal))
    tabHandle.mouseDown(with: try event(.leftMouseDown, point(tabHandle, in: second.window), second.window))
    let keyDuringTabDrag = NSApp.keyWindow
    tabHandle.mouseDragged(with: try event(.leftMouseDragged, tabDrop, second.window))
    #expect(tabHandle.dragSurface?.destinationStore === first.store)
    #expect(tabHandle.dragSurface?.placement == .reorder(tabID: original.id, after: false))
    #expect(NSApp.orderedWindows.first { $0 is BrowseWindow } === first.window)
    #expect(NSApp.keyWindow === keyDuringTabDrag)
    tabHandle.mouseUp(with: try event(.leftMouseUp, tabDrop, second.window))
    try await settle()
    #expect(first.store.selectedTab.id == tabID)
    #expect(first.store.existingController(for: moving) === controller)
    #expect(controller.webView.window === first.window)
    #expect(second.store.session.isValid && first.store.session.isValid)
    #expect(owner.windows.count == 1 && owner.windows.first === first)
    #expect(!second.window.isVisible)
    #expect(descendants(TabDragSurface.self, first.window.contentView!).isEmpty)
}

// @lat: [[tests#Empty window transfer cleanup]]
@Test(.serialized, arguments: [false, true]) @MainActor func emptyWindowTransferCleanup(paneOnly: Bool) async throws {
    guard #available(macOS 15.4, *) else { return }
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendEmptyTransfer-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let owner = BrowserWindows(root: root, persistentExtensions: false)
    owner.restore(show: false)
    let source = try #require(owner.active), target = owner.newWindow(show: false)
    defer { owner.prepareToQuit(); for context in owner.windows { context.window.close() } }
    let tab = BrowserTab()
    source.store.session.workspaces = [Workspace(name: "Tabs", tabs: [tab])]
    source.store.session.selectedTab = tab.id
    let page = tab.pages[0], controller = source.store.controller(for: page)
    source.store.saveSoon()
    let adapter = try #require(source.store.extensions.tabs[page.id])
    controller.webView.loadHTMLString("<input value='draft'><script>window.token='retained'</script>", baseURL: nil)
    for _ in 0..<50 {
        if (try? await controller.webView.evaluateJavaScript("window.token")) as? String == "retained" { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    // A rejected drop must never close the source.
    #expect(!source.store.transfer(tab: tab.id, to: target.store, at: .insert(relativeTo: UUID(), after: false)))
    #expect(owner.windows.count == 2)
    #expect(source.store.transfer(tab: tab.id, pane: paneOnly ? page.id : nil, to: target.store,
                                 at: .workspace(target.store.session.workspaces[0].id)))
    #expect(owner.windows.count == 1 && owner.windows.first === target)
    #expect(source.window.contentView == nil)
    #expect(source.store.existingController(for: page.id) == nil)
    #expect(target.store.existingController(for: page.id) === controller)
    #expect(target.store.extensions.tabs[page.id] === adapter)
    #expect(adapter.store === target.store)
    #expect(try await controller.webView.evaluateJavaScript("window.token") as? String == "retained")
    #expect(try await controller.webView.evaluateJavaScript("document.querySelector('input').value") as? String == "draft")
    #expect(!source.store.canReopenClosed && !target.store.canReopenClosed)
    let manifest = try JSONDecoder().decode([String].self, from: Data(contentsOf: root.appendingPathComponent("windows.json")))
    #expect(manifest == [target.id])
    owner.prepareToQuit()
    target.window.close()
    let restored = BrowserWindows(root: root, persistentExtensions: false)
    restored.restore(show: false)
    defer { restored.prepareToQuit(); for context in restored.windows { context.window.close() } }
    #expect(restored.windows.map(\.id) == [target.id])
    #expect(restored.active?.store.selectedTab.pages.contains { $0.id == page.id } == true)
}

}
