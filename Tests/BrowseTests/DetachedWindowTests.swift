import AppKit
import BrowseCore
import Testing
import WebKit
@testable import Browse

@Suite(.serialized) struct DetachedWindowTests {
// @lat: [[tests#Detached window ownership]]
@Test(arguments: [false, true]) @MainActor func detachedWindowOwnership(paneOnly: Bool) async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendDetach-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let owner = BrowserWindows(root: root, persistentExtensions: false)
    owner.restore(show: false)
    let source = try #require(owner.active)
    defer { owner.prepareToQuit(); for context in owner.windows { context.window.close() } }
    var tab = BrowserTab(pages: [Page(isPinned: true), Page()])
    tab.commandClickPaneID = tab.pages[1].id
    source.store.session.workspaces = [Workspace(name: "Tabs", tabs: [tab])]
    source.store.session.selectedTab = tab.id
    let page = tab.pages[0], controller = source.store.controller(for: page)
    controller.webView.loadHTMLString("<input value='unsaved'><script>window.detachToken='retained'</script>", baseURL: nil)
    for _ in 0..<40 {
        if (try? await controller.webView.evaluateJavaScript("window.detachToken")) as? String == "retained" { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    controller.webView.pageZoom = 1.25
    let screen = try #require(NSScreen.main).visibleFrame
    let point = NSPoint(x: screen.midX, y: screen.midY)
    #expect(owner.detach(tab: UUID(), pane: nil, from: source.store, at: point) == nil)
    #expect(owner.windows.count == 1)
    let destination = try #require(owner.detach(tab: tab.id, pane: paneOnly ? page.id : nil, from: source.store, at: point))
    #expect(destination.store.session.workspaces.flatMap(\.tabs).count == 1)
    #expect(destination.store.selectedTab.pages.count == (paneOnly ? 1 : 2))
    #expect(destination.store.selectedTab.isPinned)
    #expect(destination.store.existingController(for: page.id) === controller)
    #expect(source.store.existingController(for: page.id) == nil)
    #expect(controller.webView.pageZoom == 1.25)
    #expect(try await controller.webView.evaluateJavaScript("document.querySelector('input').value") as? String == "unsaved")
    #expect(try await controller.webView.evaluateJavaScript("window.detachToken") as? String == "retained")
    #expect(owner.windows.count == (paneOnly ? 2 : 1))
    #expect(destination.window.frame.intersection(screen) == destination.window.frame)
    #expect(destination.store.session.isValid && source.store.session.isValid)
    #expect(!destination.store.canReopenClosed && !source.store.canReopenClosed)
    if !paneOnly {
        #expect(destination.store.selectedTab.id == tab.id)
        #expect(destination.store.selectedTab.layout == tab.layout)
        #expect(destination.store.selectedTab.commandClickPaneID == tab.commandClickPaneID)
    }
    let manifest = try JSONDecoder().decode([String].self, from: Data(contentsOf: root.appendingPathComponent("windows.json")))
    #expect(Set(manifest) == Set(owner.windows.map(\.id)))
    let saved = try JSONDecoder().decode(BrowserSession.self,
        from: Data(contentsOf: root.appendingPathComponent("Windows/\(destination.id).json")))
    #expect(saved.selectedTab == destination.store.selectedTab.id && saved.workspaces[0].tabs[0].isPinned)
}

// @lat: [[tests#Outside-window drag gestures]]
@Test(arguments: [false, true]) @MainActor func outsideWindowDragGestures(paneOnly: Bool) async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendOutsideDrag-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let owner = BrowserWindows(root: root, persistentExtensions: false)
    owner.restore(show: false)
    let source = try #require(owner.active)
    defer { owner.prepareToQuit(); for context in owner.windows { context.window.close() } }
    let window = source.window, tab = source.store.selectedTab
    let screen = try #require(NSScreen.main).visibleFrame
    window.setFrame(NSRect(x: screen.minX - 1300, y: screen.minY - 700, width: 1400, height: 850), display: true)
    window.makeKeyAndOrderFront(nil)
    // AppKit may constrain initial placement when showing a window.
    window.setFrameOrigin(NSPoint(x: screen.minX - 1300, y: screen.minY - 700))
    let content = try #require(window.contentView)
    func settle() async throws {
        for _ in 0..<5 { content.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(50)) }
    }
    func descendants<T: NSView>(_ type: T.Type, _ view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, $0) }
    }
    try await settle()
    let pane = try #require(descendants(PaneDragSourceView.self, content).first { $0.pageID == tab.pages[0].id && $0.onHover != nil })
    let row = try #require(descendants(TabDragSourceView.self, content).first { $0.tabID == tab.id })
    let handle: NSView = paneOnly ? pane : row
    let down = handle.convert(NSPoint(x: handle.bounds.midX, y: handle.bounds.midY), to: nil)
    let outside = NSPoint(x: screen.midX, y: screen.midY)
    let drop = window.convertPoint(fromScreen: outside)
    func send(_ type: NSEvent.EventType, _ point: NSPoint) throws {
        let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        if paneOnly { window.sendEvent(event) }
        else {
            switch type {
            case .leftMouseDown: row.mouseDown(with: event)
            case .leftMouseDragged: row.mouseDragged(with: event)
            default: row.mouseUp(with: event)
            }
        }
    }
    func preview() -> DetachedDragPreview? { paneOnly ? pane.dragPreview : row.dragPreview }
    try send(.leftMouseDown, down)
    try send(.leftMouseDragged, NSPoint(x: down.x + 2, y: down.y))
    #expect(preview() == nil)
    if !paneOnly {
        try send(.leftMouseDragged, NSPoint(x: down.x + 6, y: down.y))
        #expect(preview()?.panel.isVisible == false)
        let surface = try #require(row.dragSurface)
        #expect(surface.subviews.contains { $0 is NSTextField && !$0.isHiddenOrHasHiddenAncestor })
    }
    let key = NSApp.keyWindow
    try send(.leftMouseDragged, drop)
    let card = try #require(preview())
    #expect(card.panel.isVisible && card.panel.ignoresMouseEvents && !card.panel.canBecomeKey)
    #expect(abs(max(card.panel.frame.width, card.panel.frame.height) - 250) < 1)
    #expect(NSApp.keyWindow === key)
    #expect(owner.windows.count == 1 && source.store.selectedTab.pages.count == tab.pages.count)
    #expect(WindowDragTarget.canCreateWindow(at: outside, store: source.store))
    let edge = NSPoint(x: window.frame.maxX, y: window.frame.maxY - 40)
    let nearOutside = NSPoint(x: edge.x + 2, y: edge.y)
    let nearInside = NSPoint(x: edge.x - 2, y: edge.y)
    #expect(WindowDragTarget.canCreateWindow(at: nearOutside, store: source.store))
    #expect(!WindowDragTarget.canCreateWindow(at: nearInside, store: source.store))
    #expect(!WindowDragTarget.previewExpanded(at: nearOutside, store: source.store, wasExpanded: false))
    #expect(WindowDragTarget.previewExpanded(at: nearInside, store: source.store, wasExpanded: true))
    #expect(WindowDragTarget.previewExpanded(at: NSPoint(x: edge.x + 20, y: edge.y), store: source.store, wasExpanded: false))
    #expect(!WindowDragTarget.previewExpanded(at: NSPoint(x: edge.x - 20, y: edge.y), store: source.store, wasExpanded: true))
    if let path = ProcessInfo.processInfo.environment["BEND_DRAG_PREVIEW_SNAPSHOT"], !paneOnly {
        try await settle()
        let view = try #require(card.panel.contentView)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
    try send(.leftMouseDragged, down)
    try await settle()
    #expect(WindowDragTarget.resolve(from: window, at: down) === window)
    #expect(!WindowDragTarget.canCreateWindow(at: window.convertPoint(toScreen: down), store: source.store))
    if paneOnly {
        #expect(abs(max(card.panel.frame.width, card.panel.frame.height) - 240) < 1)
    } else {
        #expect(!card.panel.isVisible)
        let surface = try #require(row.dragSurface)
        #expect(surface.subviews.contains { $0 is NSTextField && !$0.isHiddenOrHasHiddenAncestor })
        try send(.leftMouseDragged, drop)
        #expect(card.panel.isVisible)
        try send(.leftMouseDragged, down)
        #expect(!card.panel.isVisible)
    }
    if paneOnly { pane.cancelOperation(nil) } else { row.cancelOperation(nil) }
    try send(.leftMouseUp, drop)
    #expect(!card.panel.isVisible && preview() == nil && owner.windows.count == 1)
    try send(.leftMouseDown, down)
    try send(.leftMouseDragged, drop)
    try send(.leftMouseUp, drop)
    let destination = try #require(owner.windows.first { $0 !== source })
    #expect(destination.store.selectedTab.pages.contains { $0.id == tab.pages[0].id })
    #expect(destination.store.selectedTab.pages.count == (paneOnly ? 1 : tab.pages.count))
    #expect(destination.store.session.workspaces[0].tabs.count == 1)
    #expect(owner.windows.count == (paneOnly ? 2 : 1))
    #expect(preview() == nil)
    #expect(!NSApp.windows.contains { $0 is DetachedDragPanel && $0.isVisible })
}
}

// @lat: [[tests#Drag preview motion]]
@Test(arguments: [NSSize(width: 1000, height: 700), NSSize(width: 800, height: 1100)])
@MainActor func dragPreviewMotion(sourceSize: NSSize) async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendPreviewMotion-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    let source = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: sourceSize),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    source.isReleasedWhenClosed = false
    let preview = DetachedDragPreview(store: store, tab: store.selectedTab, pane: nil, title: "Motion", source: source)
    defer { preview.close(); source.close() }
    let screen = try #require(NSScreen.main).visibleFrame
    let origin = NSPoint(x: screen.minX + 200, y: screen.minY + 200)
    preview.update(at: origin, expanded: false)
    let thumbnailRatio = max(780, sourceSize.width - store.sidebarWidth) / max(500, sourceSize.height - 40)
    func expectThumbnailFit() {
        let frame = preview.panel.frame
        #expect(abs((frame.width - 8) / (frame.height - 34) - thumbnailRatio) < 0.02)
        #expect(frame.width <= 250.5 && frame.height <= 250.5)
    }
    expectThumbnailFit()
    var maximumError: CGFloat = 0
    for index in 0..<36 {
        let point = NSPoint(x: origin.x + Double(index) * 7, y: origin.y + Double(index) * 2)
        preview.update(at: point, expanded: index < 18)
        try await Task.sleep(for: .milliseconds(8))
        let frame = preview.panel.frame
        expectThumbnailFit()
        maximumError = max(maximumError, abs(frame.minX + frame.width * 0.46 - point.x),
                           abs(frame.midY - point.y))
    }
    #expect(maximumError < 1)
    let end = NSPoint(x: origin.x + 300, y: origin.y + 100)
    preview.update(at: end, expanded: true)
    try await Task.sleep(for: .milliseconds(200))
    #expect(abs(max(preview.panel.frame.width, preview.panel.frame.height) - 250) < 1)
    #expect(abs(preview.panel.frame.minX + preview.panel.frame.width * 0.46 - end.x) < 1)
    #expect(abs(preview.panel.frame.midY - end.y) < 1)
    expectThumbnailFit()
}

// @lat: [[tests#Drag preview rendered proportions]]
@Test(arguments: [NSSize(width: 1000, height: 400), NSSize(width: 400, height: 1000), NSSize(width: 1000, height: 150)])
@MainActor func dragPreviewRenderedProportions(sourceSize: NSSize) async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendPreviewRender-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    let page = store.selectedTab.pages[0]
    let source = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: sourceSize),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    source.isReleasedWhenClosed = false
    let pane = PaneDropHost(frame: NSRect(origin: .zero, size: sourceSize))
    pane.pageID = page.id
    source.contentView = pane
    let preview = DetachedDragPreview(store: store, tab: store.selectedTab, pane: page.id, title: "A long title must truncate without widening the thumbnail", source: source)
    defer { preview.close(); source.close() }
    let card = try #require(preview.panel.contentView)
    let canvas = try #require(card.subviews.compactMap { $0 as? DragPreviewCanvas }.first)
    #expect(canvas.contentSize == sourceSize)
    canvas.images[page.id] = NSImage(size: sourceSize, flipped: true) { rect in
        NSColor.red.setFill(); rect.fill(); return true
    }
    let body = NSRect(x: 0, y: 40, width: sourceSize.width, height: sourceSize.height - 40)
    let image = NSImage(size: body.size, flipped: true) { rect in
        NSColor.blue.setFill(); rect.fill()
        NSColor.green.setFill()
        NSRect(x: rect.midX - 40, y: rect.midY - 40, width: 80, height: 80).fill()
        return true
    }
    canvas.updateWebSnapshot(image, for: page.id, in: body)
    for expanded in [false, true, false] {
        preview.update(at: NSPoint(x: 400, y: 400), expanded: expanded)
        try await Task.sleep(for: .milliseconds(200))
        card.layoutSubtreeIfNeeded()
        let ratio = sourceSize.width / sourceSize.height
        #expect(min(abs(canvas.bounds.height - canvas.bounds.width / ratio),
                    abs(canvas.bounds.width - canvas.bounds.height * ratio)) < 1)
        #expect(abs(canvas.frame.minX - 4) < 0.5)
        #expect(abs(card.bounds.width - canvas.frame.maxX - 4) < 0.5)
        let bitmap = try #require(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let scan = try #require(NSBitmapImageRep(data: png))
        var green = NSRect.null
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                let c = try #require(scan.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                if c.greenComponent > c.redComponent + 0.25 && c.greenComponent > c.blueComponent + 0.25 {
                    green = green.union(NSRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
        #expect(!green.isNull)
        #expect(abs(green.width - green.height) <= 2)
        // Bottom and side pixels must contain the blue web capture, not a letterbox.
        for point in [NSPoint(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh - 4),
                      NSPoint(x: 4, y: bitmap.pixelsHigh / 2),
                      NSPoint(x: bitmap.pixelsWide - 5, y: bitmap.pixelsHigh / 2)] {
            let c = try #require(bitmap.colorAt(x: Int(point.x), y: Int(point.y))?.usingColorSpace(.deviceRGB))
            #expect(c.blueComponent > c.redComponent + 0.25 && c.blueComponent > c.greenComponent + 0.25)
        }
        if expanded {
            try #require(bitmap.representation(using: .png, properties: [:])).write(
                to: URL(fileURLWithPath: "/tmp/bend-preview-render-\(Int(sourceSize.width))-\(Int(sourceSize.height)).png"))
        }
    }
}
