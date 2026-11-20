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
    let tools = PaneChatTools(store: store, tabID: tab.id, approve: { _ in true })
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
                {"data":[{"id":"test/chat","type":"language","tags":["tool-use"],"reasoning_options":[{"type":"effort","values":["low","high","future"]}]},{"id":"test/image","type":"image"},{"id":"test/chat-batch","type":"language","tags":["tool-use"]}]}
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
    #expect(invalid.error?.contains("rejected these credentials") == true)
}

// @lat: [[lat.md/tests/ai-tests#AI preferences and tool permissions]]
@Test @MainActor func aiPreferencesAndToolPermissions() async throws {
    _ = NSApplication.shared
    let domain = "AISettingsTest-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: domain))
    defer { defaults.removePersistentDomain(forName: domain) }
    let settings = AISettings(transport: GatewayFixtureTransport(), credential: MemoryGatewayCredential(), defaults: defaults)
    let model = "test/chat"
    settings.modelDefaults[model] = .init(effort: .low)
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

    #expect(chat.modelTuning == settings.modelDefaults)
    chat.modelID = model
    chat.modelTuning[model] = .init(effort: .high, fast: true)
    let script = ChatScript()
    chat.input = "Read"
    chat.send(model: Model(model, provider: ChatProvider(script: script)))
    for _ in 0..<200 where chat.running { try await Task.sleep(for: .milliseconds(10)) }
    let requests = await script.requests
    #expect(requests.count == 2)
    #expect(requests.allSatisfy { $0.options.tuning == .init(effort: .high, fast: false) })
    let saved = try #require(store.chatHistory.records.first)
    chat.clear()
    #expect(chat.modelTuning[model] == .init(effort: .low))
    chat.restore(saved)
    #expect(chat.modelTuning[model] == .init(effort: .high, fast: true))
    #expect(AIModelControls(modelID: "gpt-6-astra", connection: "openaiKey").fast)
    let catalogModel = try #require(settings.models.first { $0.id == model })
    let controls = AIModelControls(modelID: model, connection: "gateway", advertisedEfforts: catalogModel.advertisedEfforts)
    #expect(controls.efforts == [.low, .high, .init(rawValue: "future")])
    #expect(!controls.fast)
    #expect(!AIModelControls(modelID: LocalAIProvider.modelID, connection: "openaiKey").available)

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
    #expect(restored.modelDefaults[model] == .init(effort: .low))
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

private struct EmptyChatProvider: Provider {
    func stream(_ request: ModelRequest) -> AI.Stream<ModelResponse> {
        AI.Stream { _ in ModelResponse(message: .assistant("")) }
    }
}

// @lat: [[lat.md/tests/ai-tests#Empty answer reporting]]
@Test @MainActor func aiEmptyAnswerReporting() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("EmptyChat-\(UUID())")
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    defer { store.stopWindow(); try? FileManager.default.removeItem(at: root) }
    let chat = TabChat(store: store, tabID: store.selectedTab.id)
    chat.input = "Hello"
    chat.send(model: Model("empty", provider: EmptyChatProvider()))
    for _ in 0..<200 where chat.running { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!chat.running)
    #expect(chat.error?.contains("without an answer") == true)
    #expect(chat.bubbles.count == 1 && chat.bubbles[0].isUser)
}


// @lat: [[lat.md/tests/ai-tests#Private window exclusion]]
@Test @MainActor func aiPrivateWindowExclusion() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AIPrivate-\(UUID())")
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false, isPrivate: true)
    defer { store.stopWindow(); try? FileManager.default.removeItem(at: root) }
    store.showChat()
    #expect(store.chats.isEmpty && store.openChats.isEmpty)
    let script = ChatScript()
    let chat = TabChat(store: store, tabID: store.selectedTab.id)
    chat.input = "Private prompt"
    chat.send(model: Model("test", provider: ChatProvider(script: script)))
    chat.summarize(provider: ChatProvider(script: script))
    chat.modelID = LocalAIProvider.modelID
    chat.send(model: Model(LocalAIProvider.modelID, provider: ChatProvider(script: script)))
    await Task.yield()
    #expect(await script.requests.isEmpty)
    #expect(!chat.running && chat.bubbles.isEmpty && chat.history.isEmpty)
    #expect(chat.error == "AI is unavailable in private windows.")
    let tools = PaneChatTools(store: store, tabID: store.selectedTab.id)
    #expect(tools.tools().isEmpty)
    #expect(tools.paneContext() == .array([]))
    for name in AIPaneTool.allCases.map(\.rawValue) {
        await #expect(throws: Error.self) {
            try await tools.execute(name, input: .init(pane: store.selectedTab.focusedPane.uuidString, url: "https://example.com", selector: "body", text: "test"))
        }
    }
    await #expect(throws: Error.self) {
        try await ChatPageLinks.open(URL(string: "https://example.com")!, tabID: store.selectedTab.id, store: store)
    }
}


private actor DirectKeyRequests {
    var values: [URLRequest] = []
    func append(_ request: URLRequest) { values.append(request) }
}
private struct DirectKeyFixture: HTTPTransport {
    let requests: DirectKeyRequests
    func send(_ request: URLRequest) -> AsyncThrowingStream<HTTPEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await requests.append(request)
                let invalid = request.value(forHTTPHeaderField: "Authorization") == "Bearer invalid"
                continuation.yield(.response(status: invalid ? 401 : 200))
                let data: String
                if request.url?.lastPathComponent == "models" {
                    if request.url?.host == "api.anthropic.com" {
                        if request.url?.query?.contains("after_id") == true {
                            data = #"{"data":[{"id":"claude-haiku-4-5","display_name":"Claude Haiku"}],"has_more":false}"#
                        } else {
                            data = #"{"data":[{"id":"claude-sonnet-4-6","display_name":"Claude Sonnet","capabilities":{"effort":{"supported":true,"high":{"supported":false},"max":{"supported":true}}}}],"has_more":true,"last_id":"claude-sonnet-4-6"}"#
                        }
                    } else {
                        data = #"{"data":[{"id":"gpt-4.1"},{"id":"text-embedding-3-small"},{"id":"whisper-5"},{"id":"gpt-4o-audio-preview"}]}"#
                    }
                } else if request.url?.lastPathComponent == "messages" {
                    data = "data: " + #"{"type":"message_start","message":{"usage":{}}}"# + "\n\n"
                        + "data: " + #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{}}"# + "\n\n"
                        + "data: " + #"{"type":"message_stop"}"# + "\n\n"
                } else {
                    data = "data: " + #"{"type":"response.completed","response":{"status":"completed","output":[],"usage":{}}}"# + "\n\n"
                }
                continuation.yield(.data(Data(data.utf8)))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// @lat: [[lat.md/tests/ai-tests#Direct API key connections]]
@Test @MainActor func aiDirectKeyConnections() async throws {
    let domain = "DirectKeys-\(UUID())"
    let defaults = UserDefaults(suiteName: domain)!
    defer { defaults.removePersistentDomain(forName: domain) }
    let openai = MemoryGatewayCredential(), anthropic = MemoryGatewayCredential(), gateway = MemoryGatewayCredential()
    let requests = DirectKeyRequests()
    let transport = DirectKeyFixture(requests: requests)
    let credentials: [String: any AICredentialStore] = ["openaiKey": openai, "anthropicKey": anthropic]
    let settings = AISettings(transport: transport, credential: gateway, defaults: defaults, accounts: AIOAuthAccounts(storage: MemoryGatewayCredential(), transport: transport, defaults: defaults), directCredentials: credentials)
    await settings.selectConnection("openaiKey")
    #expect(!settings.connected)
    await settings.connectSelectedKey("invalid")
    #expect(openai.value == nil && !settings.connected)
    await settings.connectSelectedKey("openai-secret")
    #expect(settings.connected && openai.value == "openai-secret")
    #expect(settings.models.map(\.id) == ["gpt-4.1"])
    var model = try settings.model(settings.modelID)
    let openaiStream = model.provider.stream(.init(modelID: model.id, messages: [.user("test")]))
    for try await _ in openaiStream {}
    var sent = try #require(await requests.values.last)
    #expect(sent.url?.absoluteString == "https://api.openai.com/v1/responses")
    #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer openai-secret")
    await settings.selectConnection("anthropicKey")
    #expect(!settings.connected && settings.models.isEmpty)
    await settings.connectSelectedKey("anthropic-secret")
    #expect(settings.models.map(\.id) == ["claude-sonnet-4-6", "claude-haiku-4-5"])
    #expect(settings.models.first?.advertisedEfforts == [.max])
    #expect(openai.value == "openai-secret" && gateway.value == nil)
    model = try settings.model(settings.modelID)
    let anthropicStream = model.provider.stream(.init(modelID: model.id, messages: [.user("test")]))
    for try await _ in anthropicStream {}
    sent = try #require(await requests.values.last)
    #expect(sent.url?.absoluteString == "https://api.anthropic.com/v1/messages")
    #expect(sent.value(forHTTPHeaderField: "x-api-key") == "anthropic-secret")
    #expect(sent.value(forHTTPHeaderField: "Authorization") == nil)
    #expect(sent.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    let restored = AISettings(transport: transport, credential: gateway, defaults: defaults, accounts: AIOAuthAccounts(storage: MemoryGatewayCredential(), transport: transport, defaults: defaults), directCredentials: credentials)
    await restored.restore()
    #expect(restored.connected && restored.activeConnection == "anthropicKey")
    restored.disconnectSelectedKey()
    #expect(anthropic.value == nil && openai.value == "openai-secret")
    #expect(!restored.connected && restored.models.isEmpty)
    await restored.selectConnection("openaiKey")
    #expect(restored.connected && restored.modelID == "gpt-4.1")
    #expect(!defaults.dictionaryRepresentation().values.contains { ($0 as? String)?.contains("-secret") == true })
}


private actor ConnectionProbeRequests {
    var requests: [ModelRequest] = []
    func record(_ request: ModelRequest) { requests.append(request) }
}
private struct ConnectionProbeProvider: Provider {
    let requests: ConnectionProbeRequests
    var fail = false
    func stream(_ request: ModelRequest) -> AI.Stream<ModelResponse> {
        AI.Stream { _ in
            await requests.record(request)
            if fail { throw AIError.http(status: 401, body: "secret error body") }
            return ModelResponse(message: .assistant("OK"))
        }
    }
}

// @lat: [[lat.md/tests/ai-tests#Connection test]]
@Test @MainActor func aiConnectionTest() async throws {
    let domain = "ConnectionProbe-\(UUID())"
    let defaults = UserDefaults(suiteName: domain)!
    defer { defaults.removePersistentDomain(forName: domain) }
    let settings = AISettings(transport: GatewayFixtureTransport(), credential: MemoryGatewayCredential(), defaults: defaults)
    await settings.connect("test-key")
    let requests = ConnectionProbeRequests()
    await settings.testConnection(model: Model("test", provider: ConnectionProbeProvider(requests: requests)))
    #expect(settings.connectionTestSucceeded && settings.connectionTestResult == "Connection successful")
    #expect(!settings.testingConnection)
    let request = try #require(await requests.requests.first)
    #expect(request.messages.count == 1 && request.messages[0].text == "This is a connection test. Reply with OK.")
    #expect(request.tools.isEmpty && !request.options.gatewayWebSearch && !request.options.includeReasoning)
    settings.modelID = "other-model"
    #expect(settings.connectionTestResult == nil)
    await settings.testConnection(model: Model("test", provider: ConnectionProbeProvider(requests: requests, fail: true)))
    #expect(!settings.connectionTestSucceeded && settings.connectionTestResult?.contains("rejected") == true)
    #expect(settings.connectionTestResult?.contains("secret") == false)
    settings.disconnect()
    #expect(settings.connectionTestResult == nil)
    await settings.testConnection(model: Model("test", provider: ConnectionProbeProvider(requests: requests)))
    #expect(await requests.requests.count == 2)
}
