import AppKit
import SwiftUI
import Markdown
import Testing
@testable import Browse

// @lat: [[lat.md/tests/ai-tests#Chat interaction]]
@Test @MainActor func chatInteraction() async throws {
    var follow = ChatScrollFollow()
    #expect(follow.shouldFollow)
    follow.interaction(true)
    #expect(!follow.shouldFollow)
    follow.geometry(nearBottom: false)
    follow.interaction(false)
    #expect(!follow.shouldFollow)
    // New streamed content does not re-enable following after the user scrolls up.
    follow.geometry(nearBottom: false)
    #expect(!follow.shouldFollow)
    follow.interaction(true)
    follow.geometry(nearBottom: true)
    follow.interaction(false)
    #expect(follow.shouldFollow)
    follow.geometry(nearBottom: false)
    #expect(follow.shouldFollow) // content growth while pinned still follows

    _ = NSApplication.shared
    let destination = URL(string: "bend-pane://00000000-0000-0000-0000-000000000001?url=https%3A%2F%2Fexample.com")!
    var opened: URL?
    let value = ChatMarkdownText.inline(Document(parsing: "[Open source](\(destination.absoluteString))"))
    let host = NSHostingView(rootView: ChatInlineText(text: value)
        .environment(\.openURL, OpenURLAction { opened = $0; return .handled })
        .frame(width: 280, height: 50)
        .background(WindowDragArea(excluded: true)))
    let window = BrowseWindow(contentRect: NSRect(x: -10000, y: -10000, width: 280, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = host
    window.orderFront(nil)
    defer { window.orderOut(nil); window.contentView = nil }
    for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
    func texts(_ view: NSView) -> [NSTextView] {
        (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(texts)
    }
    let text = try #require(texts(host).first)
    let layout = try #require(text.layoutManager)
    let container = try #require(text.textContainer)
    layout.ensureLayout(for: container)
    let rect = layout.boundingRect(forGlyphRange: NSRange(location: 1, length: 1), in: container)
    let point = text.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
    #expect(WindowDragAreaView.find(at: point, in: window) == nil)
    let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
    let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    NSApp.postEvent(up, atStart: true)
    text.mouseDown(with: down)
    // Link activation may complete on mouse-down without consuming the queued release.
    _ = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true)
    for _ in 0..<10 {
        if opened != nil { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(opened == destination)
}
