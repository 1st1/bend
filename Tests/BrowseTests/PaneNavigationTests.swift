import AppKit
import SwiftUI
import Testing
@testable import Browse

@MainActor private final class NavigationHoverWindow: BrowseWindow {
    var pointer = NSPoint(x: -100, y: -100)
    var active = true
    override var mouseLocationOutsideOfEventStream: NSPoint { pointer }
    override var isKeyWindow: Bool { active }
    override func performDrag(with event: NSEvent) {}
}

// @lat: [[lat.md/tests/pane-controls-tests#Pane history controls]]
@Test @MainActor func paneHistoryControls() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendPaneNavigation-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let firstFile = root.appendingPathComponent("first.html")
    let secondFile = root.appendingPathComponent("second.html")
    try "<title>First</title><input value='unsaved'><a id='next' href='second.html'>Next</a>".write(to: firstFile, atomically: true, encoding: .utf8)
    try "<title>Second</title><input value='second'>".write(to: secondFile, atomically: true, encoding: .utf8)
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    let pages = store.selectedTab.pages
    let first = store.controller(for: pages[0])
    let second = store.controller(for: pages[1])
    first.navigate(firstFile.absoluteString); second.navigate(firstFile.absoluteString)
    store.focus(pages[0].id)
    let host = NSHostingView(rootView: BrowserView(store: store).ignoresSafeArea())
    let window = NavigationHoverWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1400, height: 800),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.toolbarStyle = .unified
    window.toolbar = NSToolbar(identifier: "PaneNavigationTest")
    window.contentView = host; window.orderFront(nil)
    defer {
        store.downloads.shutdown()
        for page in [first, second] { page.media.detach(); page.webView.stopLoading() }
        window.orderOut(nil); window.contentView = nil
    }
    func wait(sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            host.layoutSubtreeIfNeeded()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition(), sourceLocation: sourceLocation)
    }
    func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, in: $0) }
    }
    func controlsArea(_ pane: ClippedPaneHost) -> WindowDragAreaView? {
        descendants(WindowDragAreaView.self, in: pane).first {
            $0.excluded && $0.bounds.width >= 144 && abs($0.bounds.height - 24) < 0.5
        }
    }
    try await wait { first.title == "First" && second.title == "First" && !first.isLoading && !second.isLoading }
    let firstPane = try #require(descendants(ClippedPaneHost.self, in: host).first { $0.pageID == pages[0].id })
    let secondPane = try #require(descendants(ClippedPaneHost.self, in: host).first { $0.pageID == pages[1].id })
    try await wait { controlsArea(firstPane) != nil && controlsArea(secondPane) == nil }
    #expect(!first.canGoBack && !first.canGoForward)
    let titleHandle = try #require(descendants(PaneDragSourceView.self, in: secondPane).first)
    let titleFrame = titleHandle.convert(titleHandle.bounds, to: nil)

    func hover(_ pane: ClippedPaneHost, inside: Bool) async throws {
        window.pointer = inside ? pane.convert(NSPoint(x: pane.bounds.midX, y: pane.bounds.midY), to: nil) : NSPoint(x: -100, y: -100)
        let event = try #require(NSEvent.enterExitEvent(with: inside ? .mouseEntered : .mouseExited, location: window.pointer,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, trackingNumber: 0, userData: nil))
        if inside { pane.mouseEntered(with: event) } else { pane.mouseExited(with: event) }
        try await wait { pane.isPaneHovered == inside }
    }
    try await hover(secondPane, inside: true)
    try await wait { controlsArea(secondPane) != nil }
    #expect(store.selectedTab.focusedPane == pages[0].id)
    #expect(titleHandle.convert(titleHandle.bounds, to: nil) == titleFrame)
    // Clicking an unavailable navigation direction must not navigate.
    func click(_ pane: ClippedPaneHost, forward: Bool) throws {
        let area = try #require(controlsArea(pane))
        let point = area.convert(NSPoint(x: forward ? 36 : 12, y: 12), to: nil)
        window.pointer = point
        #expect(WindowDragAreaView.find(at: point, in: window) == nil)
        try sendPaneMouse(.leftMouseDown, at: point, to: window)
        try sendPaneMouse(.leftMouseUp, at: point, to: window)
    }
    try click(secondPane, forward: false)
    #expect(second.title == "First" && !second.canGoBack)
    store.focus(pages[0].id)
    _ = try await second.webView.evaluateJavaScript("document.getElementById('next').click(); void 0")
    try await wait { second.title == "Second" && second.canGoBack }
    try await Task.sleep(for: .milliseconds(50))
    try click(secondPane, forward: false)
    #expect(store.selectedTab.focusedPane == pages[1].id)
    try await wait { second.title == "First" && second.canGoForward }
    #expect(store.selectedTab.focusedPane == pages[1].id)
    try await hover(secondPane, inside: false)
    try await wait { controlsArea(firstPane) == nil && controlsArea(secondPane) != nil }
    try click(secondPane, forward: true)
    try await wait { second.title == "Second" && !second.canGoForward }
    #expect(first.title == "First")
    #expect(try await first.webView.evaluateJavaScript("document.querySelector('input').value") as? String == "unsaved")
    _ = try await second.webView.evaluateJavaScript("document.title = 'A long pane title with enough words to use all available header space '.repeat(8)")
    try await wait { titleHandle.bounds.width > titleFrame.width + 100 }
    for width in [1000.0, 1400.0] {
        window.setContentSize(NSSize(width: width, height: 800))
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let controls = try #require(controlsArea(secondPane))
        let titleBounds = titleHandle.convert(titleHandle.bounds, to: secondPane)
        let controlBounds = controls.convert(controls.bounds, to: secondPane)
        #expect(titleBounds.maxX <= controlBounds.minX)
        // Twelve-point spacing plus the last glyph's truncation rounding.
        #expect(controlBounds.minX - titleBounds.maxX <= 21)
        #expect(controlBounds.maxX <= secondPane.bounds.maxX)
    }
    if let path = ProcessInfo.processInfo.environment["BEND_NAVIGATION_SNAPSHOT"],
       let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
    try await hover(firstPane, inside: true)
    try await wait { controlsArea(firstPane) != nil }
    window.active = false
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
    try await wait { !firstPane.isPaneHovered && controlsArea(firstPane) == nil }
    #expect(controlsArea(secondPane) != nil)
    window.active = true
    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
    try await wait { controlsArea(firstPane) != nil }
    store.newTab(address: "browse://guide")
    try await wait { firstPane.isHiddenOrHasHiddenAncestor && !firstPane.isPaneHovered }
}
