import AppKit
import SwiftUI
import Testing
import AI
@testable import Browse

// @lat: [[lat.md/tests/ai-tests#Composer keyboard controls]]
@Test @MainActor func chatComposerKeyboard() async throws {
    _ = NSApplication.shared
    var text = "abcd"
    var focused = true
    var sent: [String] = []
    let host = NSHostingView(rootView: ChatComposerInput(text: Binding(get: { text }, set: { text = $0 }),
        focused: Binding(get: { focused }, set: { focused = $0 }), canSend: true, send: { sent.append(text) })
        .frame(width: 320).padding(12))
    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 360, height: 160),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderFront(nil)
    defer { window.close() }
    for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
    func inputs(in view: NSView) -> [ChatComposerTextView] {
        (view as? ChatComposerTextView).map { [$0] } ?? view.subviews.flatMap { inputs(in: $0) }
    }
    let input = try #require(inputs(in: host).first)
    window.makeFirstResponder(input)
    input.setSelectedRange(NSRange(location: 2, length: 0))
    func enter(_ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    }
    input.keyDown(with: try enter())
    #expect(text == "ab\ncd" && sent.isEmpty)
    #expect(input.selectedRange().location == 3)
    input.keyDown(with: try enter(.shift))
    #expect(text == "ab\n\ncd" && sent.isEmpty)
    #expect(window.performKeyEquivalent(with: try enter(.command)))
    #expect(sent == ["ab\n\ncd"] && text == "ab\n\ncd")
    input.canSend = false
    #expect(input.performKeyEquivalent(with: try enter(.command)))
    #expect(sent.count == 1 && text == "ab\n\ncd")
    input.canSend = true
    input.setMarkedText("composition", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(input.performKeyEquivalent(with: try enter(.command)))
    #expect(sent.count == 1)
}

// @lat: [[lat.md/tests/ai-tests#Expanded tool card layout]]
@Test @MainActor func chatExpandedToolLayout() async throws {
    _ = NSApplication.shared
    let sources = (0..<15).map { SearchSource(url: "https://example.com/article/\($0)", title: "Search result \($0 + 1): a useful article about Swift") }
    let search = ChatBubble(isUser: false, text: "Swift concurrency and actor isolation", kind: .serverTool,
                           title: "Web search", argumentSummary: "Swift concurrency", sources: sources, state: "Completed")
    let action = ChatBubble(isUser: false, text: "", kind: .tool, toolID: "open", title: "Navigate page")
    let request = AIActionApproval.Request(callID: "open", action: .navigate, page: "https://example.com/", destination: "https://swift.org/documentation/")
    let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 16) {
        ChatActivityRow(bubble: search, expanded: true)
        ChatActivityRow(bubble: action, approval: request)
        ChatComposerInput(text: .constant("Summarize these pages\nand compare the examples"), focused: .constant(false), canSend: true, send: {})
            .padding(10).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        Spacer(minLength: 0)
    }.padding(16).frame(width: 380, height: 660).background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.dark))
    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 380, height: 660),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = host
    window.orderFront(nil)
    defer { window.close() }
    for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
    func scrolls(_ view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls)
    }
    let scroll = try #require(scrolls(host).first { ($0.documentView?.frame.height ?? 0) > $0.contentView.bounds.height + 100 })
    #expect(scroll.frame.height <= ChatActivityRow.maximumDetailsHeight + 1)
    #expect(scroll.frame.height > 200)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 100))
    scroll.reflectScrolledClipView(scroll.contentView)
    #expect(scroll.contentView.bounds.minY > 0)
    if let path = ProcessInfo.processInfo.environment["BEND_CHAT_LAYOUT_CAPTURE"] {
        scroll.contentView.scroll(to: .zero)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
}
