import AppKit
import SwiftUI
import Testing
@testable import Browse

// @lat: [[lat.md/tests/ai-tests#Chat header controls]]
@Test @MainActor func chatHeaderControls() async throws {
    _ = NSApplication.shared
    var newChats = 0
    var closes = 0
    let host = NSHostingView(rootView: HStack(spacing: 0) {
        Color.clear
        VStack(spacing: 0) {
            ChatHeader(canStartNew: true, newChat: { newChats += 1 }, close: { closes += 1 })
            Color.clear
        }.frame(width: 360)
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
    #expect(controls.count == 2)
    #expect(abs(controls[0].frame.midY - controls[1].frame.midY) <= 1)
    for width in [900.0, 600.0, 1200.0] {
        window.setContentSize(NSSize(width: width, height: 500))
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        let frame = try #require(window.contentView?.superview)
        let close = try #require(controls.first(where: { $0.toolTip == "Close chat" }))
        let new = try #require(controls.first(where: { $0.toolTip == "Clear chat" }))
        #expect(!close.isHidden && !new.isHidden)
        #expect(close.frame.maxX == frame.bounds.maxX - 10)
        #expect(new.frame.maxX == frame.bounds.maxX - 44)
        #expect(close.frame.minX - new.frame.maxX == 6)
        #expect(new.title == "Clear chat" && new.frame.width == 100)
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
}
