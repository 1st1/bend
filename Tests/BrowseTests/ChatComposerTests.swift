import AppKit
import SwiftUI
import Testing
import AI
@testable import Browse

@MainActor private final class EmptyChatCredential: AICredentialStore {
    func read() throws -> String? { nil }
    func save(_ value: String) throws {}
    func delete() throws {}
}

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
    input.unmarkText()
    input.string = ""; input.didChangeText()
    input.prompts = ["First prompt", "Last prompt\nwith two lines"]
    func key(_ code: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
    }
    input.keyDown(with: try key(126))
    #expect(text == input.prompts[1] && input.selectedRange() == NSRange(location: 0, length: (text as NSString).length))
    input.keyDown(with: try key(126))
    #expect(text == input.prompts[0])
    input.keyDown(with: try key(126))
    #expect(text == input.prompts[0])
    input.keyDown(with: try key(125))
    #expect(text == input.prompts[1])
    input.keyDown(with: try key(125))
    #expect(text.isEmpty && input.historyIndex == nil)
    input.keyDown(with: try key(126))
    input.keyDown(with: try key(53))
    #expect(text.isEmpty && input.historyIndex == nil)
    input.keyDown(with: try key(126))
    input.insertText("Edited", replacementRange: input.selectedRange())
    input.keyDown(with: try key(126))
    #expect(text == "Edited" && input.historyIndex == nil)
    #expect(!input.clearRecalledPrompt())
    #expect(sent.count == 1)
}

// @lat: [[lat.md/tests/ai-tests#Chat composer window spacing]]
@Test(arguments: [false, true], [CGFloat(200), 300, 360, 600]) @MainActor func chatComposerWindowSpacing(onLeft: Bool, panelWidth: CGFloat) async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ChatSpacing-\(UUID())")
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    let domain = "ChatSpacing-\(UUID())"
    let defaults = UserDefaults(suiteName: domain)!
    let settings = AISettings(credential: EmptyChatCredential(), defaults: defaults, directCredentials: [:])
    let chat = TabChat(store: store, tabID: store.selectedTab.id, settings: settings)
    chat.bubbles = [ChatBubble(isUser: true, text: "Test message")] + (0..<15).map {
        ChatBubble(isUser: false, text: "Response \($0): [A reference](https://example.com). " + String(repeating: "Scrollable transcript content. ", count: 5))
    }
    let host = NSHostingView(rootView: HStack(spacing: 0) {
        if !onLeft { Color.clear }
        ChatSidebar(chat: chat, panelWidth: panelWidth, onLeft: onLeft, aiSettings: settings, close: {}, settings: {})
            .frame(width: panelWidth)
        if onLeft { Color.clear }
    }.ignoresSafeArea().preferredColorScheme(.dark))
    let window = BrowseWindow(contentRect: NSRect(x: -10000, y: -10000, width: 900, height: 600),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.titleVisibility = .hidden
    window.toolbar = NSToolbar(identifier: "ChatSpacing")
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = BrowserWindowGlass(store: store, content: host)
    window.orderFront(nil)
    defer { window.close(); store.stopWindow(); defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: root) }
    for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
    func dragAreas(_ view: NSView) -> [WindowDragAreaView] {
        (view as? WindowDragAreaView).map { [$0] } ?? view.subviews.flatMap(dragAreas)
    }
    let composer = try #require(dragAreas(host).max { $0.bounds.height < $1.bounds.height })
    let rect = composer.convert(composer.bounds, to: nil)
    let content = try #require(window.contentView)
    let bounds = content.convert(content.bounds, to: nil)
    let side = onLeft ? rect.minX - bounds.minX : bounds.maxX - rect.maxX
    let bottom = rect.minY - bounds.minY
    #expect(abs(side - bottom) <= 1, "Side inset \(side), bottom inset \(bottom), composer \(rect), content \(bounds)")
    #expect(abs(side - Chrome.paneInset) <= 1)
    func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, of: type) }
    }
    let glass = try #require(descendants(host, of: FloatingPanelGlassView.self).first)
    #expect(glass.style == .regular)
    #expect(glass.convert(glass.bounds, to: nil) == rect)
    let transcript = try #require(descendants(host, of: NSScrollView.self).max { $0.bounds.height < $1.bounds.height })
    let viewport = transcript.convert(transcript.bounds, to: nil)
    #expect(abs(viewport.maxY - bounds.maxY) <= 1)
    #expect(abs(viewport.minY - bounds.minY) <= 1)
    let messages = descendants(host, of: NSTextView.self).filter { !$0.isEditable }
    #expect(!messages.isEmpty)
    for message in messages {
        #expect(message.bounds.width + 24 <= (panelWidth - 32) * 0.9 + 1)
    }
    let document = try #require(transcript.documentView)
    transcript.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.height - transcript.contentView.bounds.height))
    transcript.reflectScrolledClipView(transcript.contentView)
    let last = try #require(messages.last)
    #expect(last.convert(last.bounds, to: nil).minY >= rect.maxY)
    transcript.contentView.scroll(to: NSPoint(x: 0, y: 150))
    transcript.reflectScrolledClipView(transcript.contentView)
    #expect(transcript.contentView.bounds.minY > 0)
    #expect(glass.convert(glass.bounds, to: nil) == rect)
    let shieldPoint = NSPoint(x: rect.midX, y: rect.minY + 5)
    let frame = try #require(window.contentView?.superview)
    #expect(frame.hitTest(frame.convert(shieldPoint, from: nil)) === glass)
    let input = try #require(descendants(host, of: ChatComposerTextView.self).first)
    let inputPoint = input.convert(NSPoint(x: 15, y: 15), to: nil)
    #expect(frame.hitTest(frame.convert(inputPoint, from: nil)) === input)
    if let path = ProcessInfo.processInfo.environment["BEND_CHAT_SPACING_CAPTURE"], !onLeft,
       let frame = window.contentView?.superview, let bitmap = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
        frame.cacheDisplay(in: frame.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

private typealias ComposerState<Value> = SwiftUI.State<Value>
private struct ChatHistoryAppearanceFixture: View {
    @ComposerState private var text = ""
    let prompts: [String]
    var body: some View {
        ChatComposerInput(text: $text, focused: .constant(true), canSend: true, prompts: prompts, send: {})
            .frame(width: 280).padding(10)
    }
}

// @lat: [[lat.md/tests/ai-tests#Recalled prompt appearance]]
@Test @MainActor func chatHistoryAppearance() async throws {
    _ = NSApplication.shared
    let prompts = ["Summarize the comment thread. Any insightful retorts?", "First line\nSecond line\nThird line\nFourth line"]
    let host = NSHostingView(rootView: ChatHistoryAppearanceFixture(prompts: prompts))
    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 300, height: 180),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = host
    window.orderFront(nil)
    defer { window.close() }
    func settle() async throws {
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
    }
    func editor(_ view: NSView) -> ChatComposerTextView? {
        (view as? ChatComposerTextView) ?? view.subviews.lazy.compactMap(editor).first
    }
    try await settle()
    let input = try #require(editor(host))
    window.makeFirstResponder(input)
    func replace(_ text: String) {
        input.insertText(text, replacementRange: NSRange(location: 0, length: (input.string as NSString).length))
    }
    func key(_ code: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
    }
    var attributes: [NSAttributedString] = []
    var heights: [CGFloat] = []
    for prompt in prompts {
        replace(prompt)
        input.selectAll(nil)
        try await settle()
        attributes.append(NSAttributedString(attributedString: try #require(input.textStorage)))
        heights.append(try #require(input.enclosingScrollView).frame.height)
    }
    replace("")
    try await settle()
    for (code, index) in [(UInt16(126), 1), (126, 0), (125, 1)] {
        input.keyDown(with: try key(code))
        try await settle()
        #expect(input.string == prompts[index])
        #expect(input.attributedString().isEqual(to: attributes[index]))
        #expect(input.selectedRange() == NSRange(location: 0, length: (prompts[index] as NSString).length))
        #expect(input.enclosingScrollView?.frame.height == heights[index])
    }
    input.keyDown(with: try key(53))
    input.insertText("Typed after recall", replacementRange: input.selectedRange())
    try await settle()
    let actual = input.attributedString().attributes(at: 0, effectiveRange: nil)
    #expect(NSDictionary(dictionary: actual).isEqual(to: attributes[0].attributes(at: 0, effectiveRange: nil)))
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
