import AppKit
import SwiftUI
import Testing
@testable import Browse

// @lat: [[lat.md/tests/ai-tests#Chat header controls]]
@Test(arguments: [false, true], [CGFloat(200), 360, 600]) @MainActor func chatHeaderControls(onLeft: Bool, panelWidth: CGFloat) async throws {
    _ = NSApplication.shared
    var newChats = 0
    var closes = 0
    var summaries = 0
    let host = NSHostingView(rootView: HStack(spacing: 0) {
        if !onLeft { Color.clear }
        VStack(spacing: 0) {
            ChatHeader(onLeft: onLeft, panelWidth: panelWidth, canStartNew: true, newChat: { newChats += 1 }, close: { closes += 1 }, canSummarize: true, summarize: { summaries += 1 })
            Color.clear
        }.frame(width: panelWidth)
        if onLeft { Color.clear }
    }.ignoresSafeArea())
    host.safeAreaRegions = []
    let window = BrowseWindow(contentRect: NSRect(x: -10000, y: -10000, width: 900, height: 500),
        styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
    window.toolbar = NSToolbar(identifier: "ChatHeaderTest")
    window.titleVisibility = .hidden
    window.appearance = NSAppearance(named: .darkAqua)
    let glass = NSGlassEffectView()
    glass.contentView = host
    window.contentView = glass
    window.makeKeyAndOrderFront(nil)
    defer { window.orderOut(nil); window.contentView = nil }
    for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
    func buttons(_ view: NSView) -> [ChatHeaderNativeButton] {
        (view as? ChatHeaderNativeButton).map { [$0] } ?? view.subviews.flatMap(buttons)
    }
    let controls = buttons(try #require(window.contentView?.superview))
    #expect(controls.count == 3)
    #expect(abs(controls[0].frame.midY - controls[1].frame.midY) <= 1)
    for width in [900.0, 600.0, 1200.0] {
        window.setContentSize(NSSize(width: width, height: 500))
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        let frame = try #require(window.contentView?.superview)
        let close = try #require(controls.first(where: { $0.toolTip == "Close chat" }))
        let new = try #require(controls.first(where: { $0.toolTip == "Clear chat" }))
        #expect(!close.isHidden && !new.isHidden)
        #expect(close.frame.maxX == (onLeft ? panelWidth : frame.bounds.maxX) - 10)
        #expect(new.frame.maxX == (onLeft ? panelWidth : frame.bounds.maxX) - (panelWidth < 340 ? 44 : 116))
        #expect(close.frame.minX - new.frame.maxX == 6)
        #expect(new.title == (panelWidth < 340 ? "" : "Clear chat") && new.frame.width == (panelWidth < 340 ? 28 : 100))
        let summary = try #require(controls.first { $0.toolTip == "Summarize page locally (⌘⇧P)" })
        #expect(new.frame.minX - summary.frame.maxX == 6)
        #expect(summary.frame.minX >= (onLeft ? 0 : frame.bounds.maxX - panelWidth))
    }
    for control in controls {
        let point = control.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), to: nil)
        #expect(WindowDragAreaView.find(at: point, in: window) == nil)
        let frameView = try #require(window.contentView?.superview)
        #expect(frameView.hitTest(frameView.convert(point, from: nil)) === control)
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        window.sendEvent(down)
        window.sendEvent(up)
    }
    if let path = ProcessInfo.processInfo.environment["BEND_CHAT_HEADER_SNAPSHOT"],
       let frame = window.contentView?.superview,
       let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
        frame.cacheDisplay(in: frame.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
    #expect(newChats == 1)
    #expect(closes == 1)
    #expect(summaries == 1)
}
