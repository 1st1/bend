import AppKit
import SwiftUI
import Testing
@testable import Browse

// @lat: [[lat.md/tests/ai-tests#Chat header controls]]
@Test(arguments: [false, true], [CGFloat(200), 339, 340, 360, 600]) @MainActor func chatHeaderControls(onLeft: Bool, panelWidth: CGFloat) async throws {
    _ = NSApplication.shared
    var newChats = 0
    var closes = 0
    let host = NSHostingView(rootView: HStack(spacing: 0) {
        if !onLeft { Color.clear }
        VStack(spacing: 0) {
            ChatHeader(onLeft: onLeft, panelWidth: panelWidth, canStartNew: true, newChat: { newChats += 1 }, close: { closes += 1 })
            Color.clear
        }.frame(width: panelWidth)
        if onLeft { Color.clear }
    }.ignoresSafeArea())
    host.safeAreaRegions = []
    let window = BrowseWindow(contentRect: NSRect(x: -10000, y: -10000, width: 900, height: 500),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
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
        #expect(abs(close.frame.midY - (frame.bounds.maxY - Chrome.headerCenterY)) <= 1)
        if onLeft {
            let zoom = try #require(window.standardWindowButton(.zoomButton))
            let lights = zoom.convert(zoom.bounds, to: frame)
            #expect(new.frame.minX >= lights.maxX + 8)
            #expect(abs(close.frame.midY - lights.midY) <= 1)
        }
        #expect(close.frame.maxX == (onLeft ? panelWidth : frame.bounds.maxX) - 10)
        #expect(new.frame.maxX == (onLeft ? panelWidth : frame.bounds.maxX) - (panelWidth < 340 ? 44 : 116))
        #expect(close.frame.minX - new.frame.maxX == 6)
        #expect(new.title == (panelWidth < 340 ? "" : "Clear chat") && new.frame.width == (panelWidth < 340 ? 28 : 100))
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

// @lat: [[lat.md/tests/ai-tests#Chat header dismissal]]
@Test @MainActor func chatHeaderDismissal() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    defer { store.stopWindow(); try? FileManager.default.removeItem(at: root) }
    let id = store.selectedTab.id
    store.showChat()
    let button = ChatHeaderNativeButton()
    let anchor = ChatHeaderButtonAnchor(button: button)
    anchor.onLeft = true
    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 900, height: 500),
                          styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
    window.contentView = anchor
    window.orderFront(nil)
    defer { window.orderOut(nil); window.contentView = nil; button.removeFromSuperview() }
    anchor.observePresentation(store: store, tabID: id)
    anchor.placeButton()
    let initial = button.frame
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        let fade = try #require(button.layer?.animation(forKey: "chatReveal") as? CABasicAnimation)
        #expect((fade.fromValue as? NSNumber)?.doubleValue == 0)
        #expect(fade.duration == 0.16)
    }
    store.openChats.remove(id)
    #expect(!button.presentationActive)
    #expect(button.hitTest(NSPoint(x: 5, y: 5)) == nil)
    // SwiftUI may continue laying out the outgoing view during its longer transition.
    anchor.placeButton()
    try await Task.sleep(for: .milliseconds(140))
    #expect(button.isHidden && button.alphaValue == 0)
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { #expect(button.frame.minX < initial.minX) }
    store.openChats.insert(id)
    #expect(button.presentationActive && !button.isHidden && button.alphaValue == 1)
    #expect(button.frame == initial)
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        #expect(button.layer?.animation(forKey: "chatReveal") != nil)
    }
    // An old dismissal completion must not hide a rapidly reopened toolbar.
    store.openChats.remove(id)
    store.openChats.insert(id)
    try await Task.sleep(for: .milliseconds(140))
    #expect(button.presentationActive && !button.isHidden && button.alphaValue == 1)
}
