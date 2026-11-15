import AppKit
import SwiftUI
import BrowseCore
import Testing
import WebKit
import AI
@testable import Browse

// @lat: [[lat.md/tests/ai-tests#Saved conversations and restoration]]
@Test @MainActor func savedChatRestoration() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ChatHistory-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("session.json")
    let first = BrowserStore(sessionFile: file, persistentExtensions: false)
    first.editTab { tab in
        tab.pages[0].address = "https://example.com/article"
        tab.split(axis: .vertical, address: "https://example.org/comments")
        if case .split(let id, _, _, _, _, _) = tab.layout { tab.layout = tab.layout.resizing(id, to: 0.65) }
    }
    first.showChat()
    let tab = first.selectedTab
    let chat = try #require(first.chats[tab.id])
    chat.bubbles = [ChatBubble(isUser: true, text: "Compare these pages"),
        ChatBubble(isUser: false, text: "Read [this](\(ChatPageLinks.citation(pane: tab.pages[0].id, address: tab.pages[0].address))).")]
    chat.input = "And what about…"
    let id = chat.conversationID
    first.stopWindow()
    first.save() // A retained root window may save preferences again after closing.
    let next = BrowserStore(sessionFile: file, persistentExtensions: false)
    defer { next.stopWindow() }
    #expect(next.openChats == [tab.id])
    let resumed = try #require(next.chats[tab.id])
    #expect(resumed.conversationID == id)
    #expect(resumed.bubbles.map(\.text) == chat.bubbles.map(\.text))
    #expect(resumed.input == "And what about…")
    #expect(resumed.history.count == 2)
    #expect(next.selectedTab.layout == tab.layout)
    let saved = try #require(next.chatHistory.records.first)
    next.showChatHistory()
    #expect(next.selectedTab.pages[0].address == "bend://chats")
    #expect(next.selectedTab.title == "AI Chat History")
    var legacy = next.session
    let historyIndex = try #require(legacy.workspaces[0].tabs.firstIndex { $0.id == next.selectedTab.id })
    legacy.workspaces[0].tabs[historyIndex].title = "New tab"
    let legacyFile = root.appendingPathComponent("legacy-session.json")
    try JSONEncoder().encode(legacy).write(to: legacyFile)
    let reopened = BrowserStore(sessionFile: legacyFile, persistentExtensions: false)
    defer { reopened.stopWindow() }
    #expect(reopened.selectedTab.title == "AI Chat History")
    let count = next.session.workspaces[0].tabs.count
    next.showChatHistory()
    #expect(next.session.workspaces[0].tabs.count == count)
    #expect(next.selectedTab.title == "AI Chat History")
    next.restoreChat(saved)
    let restored = next.selectedTab
    #expect(restored.id != tab.id)
    #expect(restored.pages.map(\.address) == tab.pages.map(\.address))
    #expect(Set(restored.pages.map(\.id)).isDisjoint(with: tab.pages.map(\.id)))
    #expect(restored.focusedPane == restored.pages.last?.id)
    if case .split(_, let axis, let fraction, _, _, _) = restored.layout {
        #expect(axis == .horizontal && fraction == 0.65)
    } else { Issue.record("Lost split layout") }
    let restoredChat = try #require(next.chats[restored.id])
    #expect(restoredChat.bubbles[1].text.contains(restored.pages[0].id.uuidString))
    #expect(!restoredChat.bubbles[1].text.contains(tab.pages[0].id.uuidString))
    #expect(next.session.isValid)
    resumed.clear()
    #expect(next.chatHistory.records.contains { $0.id == id })
    #expect(resumed.bubbles.isEmpty)
    if let path = ProcessInfo.processInfo.environment["BEND_CHAT_HISTORY_SNAPSHOT"] {
        let host = NSHostingView(rootView: ChatHistoryView(store: next, history: next.chatHistory).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 850, height: 650), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host; window.orderFront(nil)
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        window.orderOut(nil); window.contentView = nil
    }
}

private struct HistorySlowProvider: Provider {
    func stream(_ request: ModelRequest) -> AI.Stream<ModelResponse> {
        AI.Stream { emit in
            emit(.textDelta("Partial text"))
            try await Task.sleep(for: .seconds(30))
            return ModelResponse(message: .assistant("Complete"))
        }
    }
}

// @lat: [[lat.md/tests/ai-tests#Deleting saved conversations]]
@Test @MainActor func savedChatDeletion() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ChatDeletion-\(UUID())")
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    defer { store.stopWindow(); try? FileManager.default.removeItem(at: root) }
    store.showChat()
    let chat = try #require(store.chats[store.selectedTab.id])
    chat.input = "Hello"
    chat.send(model: Model("test", provider: HistorySlowProvider()))
    for _ in 0..<100 where chat.bubbles.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(chat.running)
    chat.persist()
    let original = chat.conversationID
    #expect(store.chatHistory.records.count == 1)
    #expect(store.chatHistory.clear(since: .distantPast))
    try await Task.sleep(for: .milliseconds(100))
    #expect(!chat.running && chat.bubbles.isEmpty && chat.history.isEmpty)
    #expect(chat.conversationID != original)
    store.save()
    #expect(store.chatHistory.records.isEmpty)
    #expect(ChatHistoryStore(directory: root.appendingPathComponent("AIChats")).records.isEmpty)
    let privateStore = BrowserStore(sessionFile: root.appendingPathComponent("private.json"), persistentExtensions: false, sharedStore: store, isPrivate: true)
    privateStore.showChat(); privateStore.showChatHistory()
    #expect(privateStore.chats.isEmpty)
    #expect(privateStore.chatHistory !== store.chatHistory)
    privateStore.stopWindow()
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("private.json").path))
}

// @lat: [[lat.md/tests/ai-tests#Browser state clearing ranges]]
@Test @MainActor func browserStateClearingRanges() throws {
    let now = Date()
    var visits = BrowsingHistory()
    visits.record(url: "https://example.com/old", title: "Old", at: now.addingTimeInterval(-90000))
    visits.record(url: "https://example.com/new", title: "New", at: now)
    visits.clear(since: BrowserStateRange.day.cutoff(now: now))
    #expect(visits.visits.map(\.title) == ["Old"])
    #expect(BrowserStateRange.hour.cutoff(now: now) == now.addingTimeInterval(-3600))
    #expect(BrowserStateRange.week.cutoff(now: now) == now.addingTimeInterval(-604800))
    #expect(BrowserStateRange.month.cutoff(now: now) == now.addingTimeInterval(-2592000))
    #expect(BrowserStateRange.all.cutoff(now: now) == .distantPast)
    #expect(ClearBrowserStateView.cacheTypes.isDisjoint(with: ClearBrowserStateView.siteDataTypes))
    #expect(ClearBrowserStateView.siteDataTypes.contains(WKWebsiteDataTypeCookies))
    #expect(ClearBrowserStateView.siteDataTypes.contains(WKWebsiteDataTypeLocalStorage))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ChatRange-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let history = ChatHistoryStore(directory: root)
    let tab = BrowserTab()
    let old = SavedChat(id: UUID(), createdAt: now.addingTimeInterval(-90000), updatedAt: now.addingTimeInterval(-90000), tab: tab,
        bubbles: [ChatBubble(isUser: true, text: "Old")], modelID: "", draft: "", thinkingSummary: "")
    var recent = old; recent.id = UUID(); recent.updatedAt = now
    history.save(old); history.save(recent)
    #expect(history.clear(since: BrowserStateRange.day.cutoff(now: now)))
    #expect(history.records.map(\.id) == [old.id])
    #expect(ChatHistoryStore(directory: root).records.map(\.id) == [old.id])
    history.save(recent)
    #expect(history.records.map(\.id) == [old.id])
}

// @lat: [[lat.md/tests/ai-tests#Closing tabs with saved chats]]
@Test @MainActor func closingTabsWithChatsAndExtensions() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ChatClose-\(UUID())")
    let manager = ExtensionManager(root: root.appendingPathComponent("Extensions"), persistent: false, websiteDataStore: .nonPersistent())
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false, extensionManager: manager)
    defer { store.stopWindow(); try? FileManager.default.removeItem(at: root) }
    let initial = store.selectedTab.id
    store.showChat()
    store.chats[initial]?.bubbles = [ChatBubble(isUser: true, text: "First conversation")]
    store.newTab()
    let selected = store.selectedTab.id
    store.showChat()
    store.chats[selected]?.bubbles = [ChatBubble(isUser: true, text: "Second conversation")]
    // Command-W on the sole pane closes the selected tab with another tab remaining.
    store.closePane(store.selectedTab.focusedPane)
    #expect(store.selectedTab.id == initial)
    #expect(store.session.isValid)
    #expect(manager.activeID == store.selectedTab.focusedPane)
    #expect(store.chats[selected] == nil && !store.openChats.contains(selected))
    // Closing the final tab creates a valid blank replacement before synchronization.
    store.closeTab(initial)
    #expect(store.selectedTab.id != initial)
    #expect(store.session.isValid)
    #expect(manager.activeID == store.selectedTab.focusedPane)
    #expect(store.chats.isEmpty && store.openChats.isEmpty)
    #expect(store.chatHistory.records.count == 2)
    try await Task.sleep(for: .milliseconds(450))
    let saved = try JSONDecoder().decode(BrowserSession.self, from: Data(contentsOf: root.appendingPathComponent("session.json")))
    #expect(saved.isValid && saved.selectedTab == store.selectedTab.id)
    #expect(saved.openChatTabs?.isEmpty == true)
}

// @lat: [[lat.md/tests/ai-tests#Clearing open browser windows]]
@Test @MainActor func clearingOpenBrowserWindows() throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClearWindows-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let windows = BrowserWindows(root: root, persistentExtensions: false)
    windows.restore(show: false)
    let first = try #require(windows.active)
    first.store.editTab { $0.pages[0].address = "https://example.com/first" }
    first.store.showChat()
    first.store.chats[first.store.selectedTab.id]?.bubbles = [ChatBubble(isUser: true, text: "Saved conversation")]
    let second = windows.newWindow(show: false)
    second.store.editTab { $0.pages[0].address = "https://example.org/pinned"; $0.pages[0].isPinned = true }
    let privateWindow = windows.newPrivateWindow(show: false)
    privateWindow.store.editTab { $0.pages[0].address = "https://example.net/private" }
    windows.sharedStore.recordVisit(url: "https://example.com/retained", title: "Retained")
    let settings = SettingsWindowController(store: windows.sharedStore)
    defer { settings.window.close() }
    // Preserve a previously closed root window as well as currently open windows.
    first.window.close()
    try windows.sharedStore.onCloseAllWindows?()
    #expect(windows.windows.isEmpty)
    #expect(!second.window.isVisible && !privateWindow.window.isVisible)
    #expect(windows.sharedStore.history.visits.count == 1)
    #expect(windows.sharedStore.chatHistory.records.count == 1)
    #expect(!windows.sharedStore.canReopenClosed)
    let restored = BrowserWindows(root: root, persistentExtensions: false)
    restored.restore(show: false)
    defer { for context in restored.windows { context.window.close() } }
    #expect(restored.windows.count == 1)
    let session = try #require(restored.active?.store.session)
    #expect(session.isValid)
    #expect(session.workspaces.flatMap(\.tabs).flatMap(\.pages).map(\.address) == ["bend://start"])
    #expect(restored.active?.store.openChats.isEmpty == true)
}

private struct ChatResizeFixture: View {
    @ObservedObject var store: BrowserStore
    var body: some View {
        HStack(spacing: 0) {
            if store.sidebarSide == .left { Color.clear }
            Color.clear.frame(width: store.chatWidth)
                .overlay(alignment: store.sidebarSide == .right ? .trailing : .leading) {
                    SidebarResizeHandle(store: store, isChat: true).frame(width: 8)
                }
            if store.sidebarSide == .right { Color.clear }
        }
    }
}

// @lat: [[lat.md/tests/ai-tests#Chat panel resizing]]
@Test(arguments: SidebarSide.allCases) @MainActor func chatPanelResizing(side: SidebarSide) async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ChatResize-\(UUID())")
    let file = root.appendingPathComponent("session.json")
    let store = BrowserStore(sessionFile: file, persistentExtensions: false)
    defer { store.stopWindow(); try? FileManager.default.removeItem(at: root) }
    #expect(store.chatWidth == 360)
    store.sidebarSide = side
    let host = NSHostingView(rootView: ChatResizeFixture(store: store))
    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1100, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = host; window.orderFront(nil)
    defer { window.orderOut(nil); window.contentView = nil }
    func settle() async throws { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
    func handles(_ view: NSView) -> [SidebarResizeView] {
        (view as? SidebarResizeView).map { [$0] } ?? view.subviews.flatMap(handles)
    }
    try await settle()
    let handle = try #require(handles(host).first)
    let start = handle.convert(NSPoint(x: 4, y: handle.bounds.midY), to: nil)
    #expect(host.hitTest(host.convert(start, from: nil)) === handle)
    func event(_ type: NSEvent.EventType, delta: CGFloat) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: start.x + delta * (side == .right ? 1 : -1), y: start.y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }
    handle.mouseDown(with: try event(.leftMouseDown, delta: 0))
    for delta: CGFloat in [40, 40, -300, 500, 120, 120] {
        handle.mouseDragged(with: try event(.leftMouseDragged, delta: delta))
        try await settle()
        #expect(store.chatWidth == min(600, max(200, 360 + delta)))
    }
    handle.mouseUp(with: try event(.leftMouseUp, delta: 120))
    #expect(store.chatWidth == 480)
    #expect(store.sidebarWidth == 250)
    store.resizeChat(to: .nan)
    #expect(store.chatWidth == 480)
    store.save()
    let restored = BrowserStore(sessionFile: file, persistentExtensions: false)
    defer { restored.stopWindow() }
    #expect(restored.chatWidth == 480)
    restored.session.chatWidth = 900; #expect(restored.chatWidth == 600)
    restored.session.chatWidth = 0; #expect(restored.chatWidth == 200)
    restored.session.chatWidth = .infinity; #expect(restored.chatWidth == 360)
}
