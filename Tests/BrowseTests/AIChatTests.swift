import AppKit
import BrowseCore
import Testing
import AI
@testable import Browse

private actor ChatScript {
    var requests: [ModelRequest] = []
    func response(_ request: ModelRequest) -> ModelResponse {
        requests.append(request)
        if requests.count == 1 {
            return ModelResponse(message: .assistant("", toolCalls: [ToolCall(id: "panes", name: "read_pane", arguments: "{}")]), finishReason: "tool_calls")
        }
        return ModelResponse(message: .assistant("Here are your panes."))
    }
}
private struct ChatProvider: Provider {
    let script: ChatScript
    func stream(_ request: ModelRequest) -> AI.Stream<ModelResponse> {
        AI.Stream { emit in
            let response = await script.response(request)
            if !response.text.isEmpty { emit(.textDelta(response.text)) }
            return response
        }
    }
}
private struct WaitingChatProvider: Provider {
    func stream(_ request: ModelRequest) -> AI.Stream<ModelResponse> {
        AI.Stream { emit in
            emit(.textDelta("Partial response"))
            try await Task.sleep(for: .seconds(30))
            return ModelResponse(message: .assistant("Done"))
        }
    }
}

// @lat: [[lat.md/tests/ai-tests#Conversation lifecycle]]
@Test @MainActor func aiConversationLifecycle() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AIChat-\(UUID())")
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    defer { store.stopWindow(); try? FileManager.default.removeItem(at: root) }
    let first = store.selectedTab.id
    store.showChat()
    let chat = try #require(store.chats[first])
    chat.input = "List my panes"
    let script = ChatScript()
    chat.send(model: Model("test", provider: ChatProvider(script: script)))
    for _ in 0..<200 where chat.running { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!chat.running)
    #expect(chat.bubbles.last?.text == "Here are your panes.")
    let requests = await script.requests
    #expect(requests.count == 2)
    #expect(requests.last?.messages.last?.toolResults.first?.name == "read_pane")
    #expect(chat.history.map(\.role) == [.user, .assistant, .tool, .assistant])
    store.newTab(); store.showChat()
    #expect(store.chats[store.selectedTab.id] !== chat)
    #expect(store.chats[store.selectedTab.id]?.history.isEmpty == true)
    store.select(first)
    #expect(store.chats[first] === chat)
    chat.input = "Continue"
    chat.send(model: Model("test", provider: WaitingChatProvider()))
    for _ in 0..<100 where chat.bubbles.last?.text != "Partial response" { try await Task.sleep(for: .milliseconds(10)) }
    chat.stop()
    for _ in 0..<100 where chat.running { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!chat.running)
    #expect(chat.error == "Response stopped.")
    #expect(chat.bubbles.last?.text == "Partial response")
    store.closeTab(first)
    #expect(store.chats[first] == nil && !store.openChats.contains(first))
}

// @lat: [[lat.md/tests/ai-tests#Pane tool boundaries]]
@Test @MainActor func aiPaneToolBoundaries() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AITools-\(UUID())")
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    defer { store.stopWindow(); try? FileManager.default.removeItem(at: root) }
    let page = Page(address: "https://example.com")
    let other = Page(address: "https://other.example")
    let tab = BrowserTab(title: "Chat", pages: [page])
    let otherTab = BrowserTab(title: "Other", pages: [other])
    store.session.workspaces = [Workspace(name: "Tabs", tabs: [tab, otherTab])]
    store.session.selectedTab = tab.id
    let tools = PaneChatTools(store: store, tabID: tab.id)
    let list = tools.paneContext()
    #expect(try list.jsonString().contains(page.id.uuidString))
    #expect(try !list.jsonString().contains(other.id.uuidString))
    await #expect(throws: Error.self) {
        try await tools.execute("read_pane", input: .init(pane: other.id.uuidString))
    }
    await #expect(throws: Error.self) {
        try await tools.execute("navigate_pane", input: .init(pane: page.id.uuidString, url: "file:///etc/passwd"))
    }
    let controller = store.controller(for: page)
    controller.webView.loadHTMLString("""
    <html><body><h1>Pane fixture</h1><input id="name"><input id="password" type="password" value="secret-value"><button id="button" onclick="document.querySelector('h1').textContent='Clicked'">Click me</button></body></html>
    """, baseURL: URL(string: "https://example.com"))
    for _ in 0..<200 {
        if controller.webView.url != nil && !controller.webView.isLoading { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    let read = try await tools.execute("read_pane", input: .init(pane: page.id.uuidString))
    #expect(try read.jsonString().contains("Pane fixture"))
    #expect(try !read.jsonString().contains("secret-value"))
    _ = try await tools.execute("fill_element", input: .init(pane: page.id.uuidString, selector: "#name", text: "Hello"))
    let value = try await controller.webView.evaluateJavaScript("document.querySelector('#name').value")
    #expect(value as? String == "Hello")
    await #expect(throws: Error.self) {
        try await tools.execute("fill_element", input: .init(pane: page.id.uuidString, selector: "#password", text: "no"))
    }
    _ = try await tools.execute("click_element", input: .init(pane: page.id.uuidString, selector: "#button"))
    #expect(try await tools.execute("read_pane", input: .init(pane: page.id.uuidString)).jsonString().contains("Clicked"))
    store.session.workspaces[0].tabs[0].pages = [Page()]
    await #expect(throws: Error.self) {
        try await tools.execute("read_pane", input: .init(pane: page.id.uuidString))
    }
}

@MainActor private final class MemoryGatewayCredential: AICredentialStore {
    var value: String?
    func read() -> String? { value }
    func save(_ key: String) { value = key }
    func delete() { value = nil }
}
private struct GatewayFixtureTransport: HTTPTransport {
    var status = 200
    func send(_ request: URLRequest) -> AsyncThrowingStream<HTTPEvent, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.response(status: status))
            if request.url?.lastPathComponent == "models" {
                continuation.yield(.data(Data("""
                {"data":[{"id":"test/chat","type":"language","tags":["tool-use"]},{"id":"test/image","type":"image"},{"id":"test/chat-batch","type":"language","tags":["tool-use"]}]}
                """.utf8)))
            } else {
                continuation.yield(.data(Data("""
                {"balance":"5"}
                """.utf8)))
            }
            continuation.finish()
        }
    }
}
// @lat: [[lat.md/tests/ai-tests#Gateway connection state]]
@Test @MainActor func aiGatewayConnectionState() async throws {
    let domain = "AIGatewayTest-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: domain))
    defer { defaults.removePersistentDomain(forName: domain) }
    let credential = MemoryGatewayCredential()
    let settings = AISettings(transport: GatewayFixtureTransport(), credential: credential, defaults: defaults)
    #expect(!settings.connected && credential.value == nil)
    await settings.connect(" test-key ")
    #expect(settings.connected && credential.value == "test-key")
    #expect(settings.models.map(\.id) == ["test/chat"])
    #expect(settings.modelID == "test/chat")
    settings.disconnect()
    #expect(!settings.connected && credential.value == nil)
    #expect(throws: Error.self) { try settings.model("test/chat") }
    let invalid = AISettings(transport: GatewayFixtureTransport(status: 401), credential: credential, defaults: defaults)
    await invalid.connect("rejected-secret")
    #expect(!invalid.connected && credential.value == nil)
    #expect(invalid.error?.contains("rejected-secret") == false)
    #expect(invalid.error?.contains("rejected this key") == true)
}

// @lat: [[lat.md/tests/ai-tests#AI preferences and tool permissions]]
@Test @MainActor func aiPreferencesAndToolPermissions() async throws {
    _ = NSApplication.shared
    let domain = "AISettingsTest-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: domain))
    defer { defaults.removePersistentDomain(forName: domain) }
    let settings = AISettings(transport: GatewayFixtureTransport(), credential: MemoryGatewayCredential(), defaults: defaults)
    settings.modelID = "preferred/model"
    await settings.refreshModels()
    #expect(settings.modelID == "preferred/model") // Catalog refresh must not overwrite a preference.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(domain)
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    defer { store.stopWindow(); try? FileManager.default.removeItem(at: root) }
    let chat = TabChat(store: store, tabID: store.selectedTab.id, settings: settings)
    #expect(chat.modelID == "preferred/model")
    chat.modelID = "chat/override"
    #expect(settings.modelID == "preferred/model")
    settings.modelID = "preferred/new"
    #expect(chat.modelID == "chat/override")
    chat.clear()
    #expect(chat.modelID == "preferred/new")

    let tools = PaneChatTools(store: store, tabID: store.selectedTab.id, settings: settings)
    #expect(Set(tools.tools().map { $0.definition.name }) == Set(AIPaneTool.allCases.map(\.rawValue)))
    let advertisedBeforeDisable = tools.tools()
    settings.setToolEnabled("read_pane", enabled: false)
    #expect(!tools.tools().contains { $0.definition.name == "read_pane" || $0.definition.name == "list_panes" })
    // Already advertised tools must check the live switch when dispatched.
    let result = try await Agent(tools: advertisedBeforeDisable).run(
        Model("test", provider: ChatProvider(script: ChatScript())), messages: [.user("List panes")]).result
    #expect(result.messages[2].toolResults.first?.isError == true)
    #expect(result.messages[2].toolResults.first?.value.string?.contains("disabled") == true)
    for tool in AIPaneTool.allCases { settings.setToolEnabled(tool.rawValue, enabled: false) }
    #expect(tools.tools().isEmpty)
    let restored = AISettings(transport: GatewayFixtureTransport(), credential: MemoryGatewayCredential(), defaults: defaults)
    #expect(restored.modelID == "preferred/new")
    #expect(restored.disabledTools == Set(AIPaneTool.allCases.map(\.rawValue)))
    settings.setToolEnabled("read_pane", enabled: true)
    #expect(try tools.paneContext().jsonString().contains(store.selectedTab.focusedPane.uuidString))
}

// @lat: [[lat.md/tests/ai-tests#Custom system prompt]]
@Test @MainActor func aiCustomSystemPrompt() async throws {
    _ = NSApplication.shared
    let domain = "AIPromptTest-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: domain))
    defer { defaults.removePersistentDomain(forName: domain) }
    let settings = AISettings(transport: GatewayFixtureTransport(), credential: MemoryGatewayCredential(), defaults: defaults)
    #expect(settings.systemPrompt == AISettings.defaultSystemPrompt && !settings.hasCustomSystemPrompt)
    settings.systemPrompt = "Answer in one sentence."
    let restored = AISettings(transport: GatewayFixtureTransport(), credential: MemoryGatewayCredential(), defaults: defaults)
    #expect(restored.systemPrompt == settings.systemPrompt && restored.hasCustomSystemPrompt)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(domain)
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    let chat = TabChat(store: store, tabID: store.selectedTab.id, settings: settings)
    defer { chat.stop(); store.stopWindow(); try? FileManager.default.removeItem(at: root) }
    let script = ChatScript()
    let model = Model("test", provider: ChatProvider(script: script))
    chat.input = "First message"; chat.send(model: model)
    for _ in 0..<200 where chat.running { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!chat.running)
    let first = await script.requests
    #expect(first.allSatisfy { $0.messages.first?.text.hasPrefix("Answer in one sentence.") == true })
    #expect(chat.history.allSatisfy { $0.role != .system })
    settings.systemPrompt = "Answer in French."
    chat.input = "Follow up"; chat.send(model: model)
    for _ in 0..<200 where chat.running { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!chat.running)
    let requests = await script.requests
    #expect(requests.last?.messages.first?.text.hasPrefix("Answer in French.") == true)
    #expect(requests.last?.messages.filter { $0.role == .system }.count == 1)
    settings.resetSystemPrompt()
    #expect(!settings.hasCustomSystemPrompt && defaults.object(forKey: "ai.systemPrompt") == nil)
    #expect(AISettings(transport: GatewayFixtureTransport(), credential: MemoryGatewayCredential(), defaults: defaults).systemPrompt == AISettings.defaultSystemPrompt)
}

// @lat: [[lat.md/tests/ai-tests#Paginated page reads]]
@Test @MainActor func aiPaginatedPageReads() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AIPagination-\(UUID())")
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    defer { store.stopWindow(); try? FileManager.default.removeItem(at: root) }
    let page = Page(address: "https://example.com")
    let tab = BrowserTab(title: "Read", pages: [page])
    store.session.workspaces = [Workspace(name: "Tabs", tabs: [tab])]
    store.session.selectedTab = tab.id
    let controller = store.controller(for: page)
    let text = String(repeating: "abc🌍", count: 13000)
    let links = (0..<205).map { "<a id='a\($0)' href='#a\($0)'>Link \($0)</a>" }.joined()
    controller.webView.loadHTMLString("<body><div>\(text)</div>\(links)</body>", baseURL: URL(string: "https://example.com"))
    for _ in 0..<200 {
        if controller.webView.url != nil && !controller.webView.isLoading { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    let expected = try #require(try await controller.webView.evaluateJavaScript("document.body.innerText") as? String)
    let tools = PaneChatTools(store: store, tabID: tab.id)
    func read(_ cursor: String? = nil) async throws -> JSONValue {
        let result = try await tools.execute("read_pane", input: .init(cursor: cursor, pane: page.id.uuidString))
        return try JSONDecoder().decode(JSONValue.self, from: Data(try #require(result.string).utf8))
    }
    var chunk = try await read()
    let oldCursor = try #require(chunk["next_cursor"]?.string)
    _ = try await controller.webView.evaluateJavaScript("document.body.append('LIVE CHANGE')")
    var combined = ""; var references = 0; var elements = 0; var count = 0
    while true {
        let pageText = chunk["text"]?.string ?? ""
        if !pageText.isEmpty {
            #expect(chunk["text_start"] == .integer(Int64(combined.unicodeScalars.count + 1)))
            #expect(chunk["text_end"] == .integer(Int64(combined.unicodeScalars.count + pageText.unicodeScalars.count)))
        }
        combined += pageText
        if case .array(let values) = chunk["references"] { references += values.count; #expect(values.count <= 100) }
        if case .array(let values) = chunk["elements"] { elements += values.count; #expect(values.count <= 100) }
        count += 1
        guard let cursor = chunk["next_cursor"]?.string else { break }
        #expect(chunk["has_more"] == .bool(true))
        chunk = try await read(cursor)
        if count > 10 { Issue.record("Cursor failed to terminate"); break }
    }
    #expect(combined == expected)
    #expect(references == 205 && elements == 205)
    #expect(chunk["has_more"] == .bool(false))
    _ = try await read()
    await #expect(throws: Error.self) { try await read(oldCursor) }
    await #expect(throws: Error.self) { try await read("invalid") }
}

// @lat: [[lat.md/tests/ai-tests#Pane prompt context]]
@Test @MainActor func aiPanePromptContext() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AIPaneContext-\(UUID())")
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    defer { store.stopWindow(); try? FileManager.default.removeItem(at: root) }
    let tabID = store.selectedTab.id
    let tools = PaneChatTools(store: store, tabID: tabID)
    let paneID = store.selectedTab.focusedPane
    let rendered = tools.renderPrompt("Before ${panes} After")
    #expect(rendered.hasPrefix("Before Current tab panes"))
    #expect(rendered.hasSuffix(" After"))
    #expect(rendered.contains(paneID.uuidString))
    #expect(rendered.contains("\"active\":true"))
    #expect(!tools.tools().contains { $0.definition.name == "list_panes" })
    let script = ChatScript()
    let provider = PaneContextProvider(base: ChatProvider(script: script)) { await tools.renderPrompt("${panes}") }
    let model = Model("test", provider: provider)
    _ = try await AI.stream(model, messages: [.system("old"), .user("First")]).result
    store.session.workspaces[0].tabs[0].pages = [Page(address: "https://changed.example")]
    _ = try await AI.stream(model, messages: [.system("old"), .user("Second")]).result
    let requests = await script.requests
    #expect(requests[0].messages.first?.text.contains(paneID.uuidString) == true)
    #expect(requests[1].messages.first?.text.contains("changed.example") == true)
    #expect(requests[1].messages.first?.text.contains(paneID.uuidString) == false)
    #expect(requests.allSatisfy { $0.messages.filter { $0.role == .system }.count == 1 })
}
