import AppKit
import BrowseCore
import Testing
import AI
import FoundationModels
@testable import Browse

private actor LocalRequests {
    var prompts: [String] = []
    func record(_ request: ModelRequest) { prompts.append(request.messages.map(\.text).joined(separator: "\n")) }
}
private struct LocalFixtureProvider: Provider {
    let requests: LocalRequests
    var wait = false
    func stream(_ request: ModelRequest) -> AI.Stream<ModelResponse> {
        AI.Stream { emit in
            await requests.record(request)
            emit(.textDelta("Local fixture answer"))
            if wait { try await Task.sleep(for: .seconds(30)) }
            return ModelResponse(message: .assistant("Local fixture answer"))
        }
    }
}

// @lat: [[lat.md/tests/ai-tests#Local summaries and chat]]
@Test @MainActor func localSummariesAndChat() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalAI-\(UUID())")
    let defaults = UserDefaults(suiteName: "LocalAI-\(UUID())")!
    let settings = AISettings(defaults: defaults)
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    defer { store.stopWindow(); try? FileManager.default.removeItem(at: root) }
    let page = Page(address: "https://example.com/article")
    let tab = BrowserTab(title: "Local", pages: [page])
    store.session.workspaces = [Workspace(name: "Local", tabs: [tab])]
    store.session.selectedTab = tab.id
    let controller = store.controller(for: page)
    controller.webView.loadHTMLString("<body><p>" + String(repeating: "Article fact. ", count: 2100)
        + " FINAL_PAGE_FACT</p><textarea>PRIVATE_DRAFT</textarea><input value='PRIVATE_VALUE'><div contenteditable>PRIVATE_EDIT</div></body>", baseURL: URL(string: page.address))
    for _ in 0..<300 {
        if controller.webView.url != nil && !controller.webView.isLoading { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    let chat = TabChat(store: store, tabID: tab.id, settings: settings)
    #expect(!settings.connected)
    #expect(try settings.model(LocalAIProvider.modelID).id == LocalAIProvider.modelID)
    chat.modelID = "cloud-choice"
    chat.input = "Unsent draft"
    let requests = LocalRequests()
    let provider = LocalFixtureProvider(requests: requests)
    #expect(chat.canSummarize)
    chat.summarize(provider: provider)
    for _ in 0..<500 where chat.running { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!chat.running && chat.error == nil)
    #expect(chat.modelID == "cloud-choice" && chat.input == "Unsent draft")
    #expect(chat.bubbles.last?.text.contains("[Source page](bend-pane://") == true)
    let prompts = await requests.prompts
    #expect(prompts.count > 2)
    #expect(prompts.joined().contains("FINAL_PAGE_FACT"))
    #expect(!prompts.joined().contains("PRIVATE_"))
    #expect(!prompts.joined().contains("Unsent draft"))
    #expect(prompts.allSatisfy { $0.utf8.count < 4000 })

    settings.setToolEnabled("read_pane", enabled: false)
    chat.summarize(provider: provider)
    for _ in 0..<100 where chat.running { try await Task.sleep(for: .milliseconds(10)) }
    #expect(chat.error?.contains("disabled") == true)
    #expect(await requests.prompts.count == prompts.count)

    chat.discussSelection("ONLY_SELECTED_PASSAGE", explain: true, provider: provider)
    for _ in 0..<100 where chat.running { try await Task.sleep(for: .milliseconds(10)) }
    #expect(chat.error == nil)
    let selectedPrompt = await requests.prompts.last ?? ""
    #expect(selectedPrompt.contains("ONLY_SELECTED_PASSAGE") && selectedPrompt.contains("Explain the selected text"))
    #expect(!selectedPrompt.contains("FINAL_PAGE_FACT"))
    #expect(chat.modelID == "cloud-choice" && chat.input == "Unsent draft")
    chat.discussSelection("SECOND_SELECTED_PASSAGE", explain: false, provider: provider)
    for _ in 0..<100 where chat.running { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await requests.prompts.last?.contains("SECOND_SELECTED_PASSAGE") == true)
    #expect(await requests.prompts.last?.contains("Explain the selected text") == false)

    chat.modelID = LocalAIProvider.modelID
    chat.input = "Hello locally"
    chat.send(model: Model(LocalAIProvider.modelID, provider: provider))
    for _ in 0..<100 where chat.running { try await Task.sleep(for: .milliseconds(10)) }
    #expect(chat.error == nil && chat.bubbles.last?.text == "Local fixture answer")
    chat.input = "Wait locally"
    chat.send(model: Model(LocalAIProvider.modelID, provider: LocalFixtureProvider(requests: requests, wait: true)))
    for _ in 0..<100 where chat.bubbles.last?.text != "Local fixture answer" { try await Task.sleep(for: .milliseconds(10)) }
    chat.stop()
    for _ in 0..<100 where chat.running { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!chat.running && chat.error == "Response stopped.")
    chat.clear()
    #expect(chat.modelID == LocalAIProvider.modelID)
}

@Test func localChunkBudgets() async throws {
    let text = String(repeating: "日本語👩🏽‍💻 words\n", count: 400)
    let chunks = LocalPageAI.chunks(text)
    #expect(chunks.joined() == text)
    #expect(chunks.allSatisfy { $0.utf8.count <= LocalPageAI.chunkBytes })
    let requests = LocalRequests()
    let condensed = try await LocalPageAI(provider: LocalFixtureProvider(requests: requests)).compact(text)
    #expect(condensed.utf8.count <= LocalPageAI.chunkBytes)
    #expect(await requests.prompts.count == chunks.count)
}

@Test func localModelSmoke() async throws {
    guard ProcessInfo.processInfo.environment["BEND_TEST_LOCAL_AI"] == "1" else { return }
    try LocalAIProvider.checkAvailability()
    let engine = LocalPageAI(provider: LocalAIProvider())
    let page = String(repeating: "Bend is a native browser. It supports tabs and tiled panes. ", count: 50)
    let notes = try await engine.compact(page)
    #expect(notes.utf8.count <= LocalPageAI.chunkBytes)
    let stream = engine.request("Summarize these page notes in one sentence: " + notes)
    defer { stream.cancel() }
    let response = try await stream.result
    #expect(!response.text.isEmpty)
}

private actor LocalActionScript {
    var requests: [ModelRequest] = []
    let pane: String
    init(pane: String) { self.pane = pane }
    func next(_ request: ModelRequest) throws -> ModelResponse {
        requests.append(request)
        let calls: [(String, JSONValue)] = [
            ("read_pane", .object(["pane": .string(pane)])),
            ("fill_element", .object(["pane": .string(pane), "selector": .string("#field"), "text": .string("Local input")])),
            ("click_element", .object(["pane": .string(pane), "selector": .string("#activate")]))
        ]
        if requests.count <= calls.count {
            let (name, input) = calls[requests.count - 1]
            return ModelResponse(message: .assistant("", toolCalls: [.init(id: UUID().uuidString, name: name, arguments: try input.jsonString())]), finishReason: "tool_calls")
        }
        return ModelResponse(message: .assistant("Finished locally."))
    }
}
private struct LocalActionProvider: Provider {
    let script: LocalActionScript
    func stream(_ request: ModelRequest) -> AI.Stream<ModelResponse> {
        AI.Stream { emit in
            let response = try await script.next(request)
            for call in response.message.toolCalls { emit(.toolCall(call)) }
            if !response.text.isEmpty { emit(.textDelta(response.text)) }
            return response
        }
    }
}

// @lat: [[lat.md/tests/ai-tests#Local browser tools]]
@Test @MainActor func localBrowserTools() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalTools-\(UUID())")
    let settings = AISettings(defaults: UserDefaults(suiteName: "LocalTools-\(UUID())")!)
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    defer { store.stopWindow(); try? FileManager.default.removeItem(at: root) }
    let page = Page(address: "https://example.com/tools")
    let tab = BrowserTab(title: "Tools", pages: [page])
    store.session.workspaces = [Workspace(name: "Tools", tabs: [tab])]
    store.session.selectedTab = tab.id
    let controller = store.controller(for: page)
    controller.webView.loadHTMLString("<body><input id='field'><button id='activate' onclick=\"this.textContent='Activated'\">Activate</button><p>" + String(repeating: "fact ", count: 800) + "END_OF_ARTICLE</p></body>", baseURL: URL(string: page.address))
    for _ in 0..<300 {
        if controller.webView.url != nil && !controller.webView.isLoading { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    let compact = PaneChatTools(store: store, tabID: tab.id, settings: settings, compactReads: true)
    var cursor: String?, text = "", count = 0
    repeat {
        let result = try await compact.execute("read_pane", input: .init(cursor: cursor, pane: page.id.uuidString))
        guard case .string(let json) = result else { Issue.record("Missing read"); return }
        let chunk = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        guard case .string(let part) = chunk["text"] else { Issue.record("Missing text"); return }
        #expect(part.unicodeScalars.count <= 800)
        text += part; count += 1
        if case .string(let next) = chunk["next_cursor"] { cursor = next } else { cursor = nil }
    } while cursor != nil && count < 20
    #expect(count > 1 && text.contains("END_OF_ARTICLE"))

    let chat = TabChat(store: store, tabID: tab.id, settings: settings)
    store.chats[tab.id] = chat; store.openChats.insert(tab.id)
    chat.modelID = LocalAIProvider.modelID
    chat.input = "Fill the field and activate the button."
    let script = LocalActionScript(pane: page.id.uuidString)
    chat.send(model: Model(LocalAIProvider.modelID, provider: LocalActionProvider(script: script)))
    for _ in 0..<300 where chat.actionApproval.pending == nil { try await Task.sleep(for: .milliseconds(10)) }
    let fill = try #require(chat.actionApproval.pending)
    #expect(fill.action == .fill)
    #expect(try await controller.webView.evaluateJavaScript("document.querySelector('#field').value") as? String == "")
    chat.approveAction(fill.id)
    for _ in 0..<300 where chat.actionApproval.pending?.action != .click { try await Task.sleep(for: .milliseconds(10)) }
    let click = try #require(chat.actionApproval.pending)
    #expect(try await controller.webView.evaluateJavaScript("document.querySelector('#field').value") as? String == "Local input")
    #expect(try await controller.webView.evaluateJavaScript("document.querySelector('#activate').textContent") as? String == "Activate")
    // Live revocation still applies after the model advertised the tool.
    settings.setToolEnabled("click_element", enabled: false)
    chat.approveAction(click.id)
    for _ in 0..<300 where chat.running { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!chat.running && chat.error == nil)
    #expect(try await controller.webView.evaluateJavaScript("document.querySelector('#activate').textContent") as? String == "Activate")
    let requests = await script.requests
    #expect(Set(requests[0].tools.map(\.name)) == Set(AIPaneTool.allCases.filter { $0 != .screenshot }.map(\.rawValue)))
    #expect(requests.allSatisfy { !$0.options.gatewayWebSearch })
    #expect(requests.last?.messages.last?.toolResults.first?.isError == true)
    #expect(chat.bubbles.contains { $0.kind == .tool && $0.title == "Fill text fields" && $0.state == "Completed" })
}

@Test func localNativeToolSmoke() async throws {
    guard ProcessInfo.processInfo.environment["BEND_TEST_LOCAL_AI"] == "1" else { return }
    let tool = AI.Tool(name: "lookup_code", description: "Look up the secret code for a named city.", parameters: .object([
        "type": .string("object"), "properties": .object(["city": .object(["type": .string("string")])]), "required": .array([.string("city")])
    ])) { arguments, _ in
        #expect(arguments["city"] == .string("Paris"))
        return .string("The secret code is ORCHID.")
    }
    let agent = try Agent(tools: [tool], maxSteps: 3, maxConcurrentTools: 1)
    let stream = agent.run(Model(LocalAIProvider.modelID, provider: LocalAIProvider()), messages: [
        .system("Use lookup_code to look up the code. After the tool result, answer with that code. Never invent a code."), .user("What is the secret code for Paris?")
    ])
    let timeout = Task { try await Task.sleep(for: .seconds(45)); stream.cancel() }
    defer { timeout.cancel(); stream.cancel() }
    let result = try await stream.result
    #expect(result.messages.contains { !$0.toolResults.isEmpty })
    #expect(result.output.uppercased().contains("ORCHID"))
}

@Test func localFailureCategories() {
    let context = LanguageModelSession.GenerationError.Context(debugDescription: "PRIVATE_PROMPT")
    let guardrail = LocalAIProvider.failure(LanguageModelSession.GenerationError.guardrailViolation(context))
    let overflow = LocalAIProvider.failure(LanguageModelSession.GenerationError.exceededContextWindowSize(context))
    #expect(guardrail.description.contains("guardrails"))
    #expect(overflow.description.contains("context window"))
    #expect(!guardrail.description.contains("PRIVATE_PROMPT"))
    let underlying = NSError(domain: "LocalTest", code: 17, userInfo: [NSLocalizedDescriptionKey: "PRIVATE_PROMPT"])
    #expect(LocalAIProvider.failure(underlying).description.contains("LocalTest, code 17"))
    #expect(!LocalAIProvider.failure(underlying).description.contains("PRIVATE_PROMPT"))
}

@Test @MainActor func localNativeBrowserSmoke() async throws {
    guard ProcessInfo.processInfo.environment["BEND_TEST_LOCAL_AI"] == "1" else { return }
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalNativeBrowser-\(UUID())")
    let settings = AISettings(defaults: UserDefaults(suiteName: "LocalNativeBrowser-\(UUID())")!)
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    defer { store.stopWindow(); try? FileManager.default.removeItem(at: root) }
    let page = Page(address: "https://example.com/local-fixture")
    let tab = BrowserTab(title: "Fixture", pages: [page])
    store.session.workspaces = [Workspace(name: "Fixture", tabs: [tab])]
    store.session.selectedTab = tab.id
    let controller = store.controller(for: page)
    controller.webView.loadHTMLString("<body><button id='activate' onclick=\"this.textContent='Activated'\">Activate</button></body>", baseURL: URL(string: page.address))
    for _ in 0..<300 {
        if controller.webView.url != nil && !controller.webView.isLoading { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    let chat = TabChat(store: store, tabID: tab.id, settings: settings)
    store.chats[tab.id] = chat; store.openChats.insert(tab.id)
    chat.modelID = LocalAIProvider.modelID
    chat.input = "Read the active page, then click its Activate button once. Afterward read the page to verify the button says Activated."
    chat.send()
    var approvals = 0
    for _ in 0..<3000 where chat.running {
        if let pending = chat.actionApproval.pending {
            #expect(pending.action == .click)
            if pending.action == .click && approvals == 0 {
                #expect(try await controller.webView.evaluateJavaScript("document.querySelector('#activate').textContent") as? String == "Activate")
                chat.approveAction(pending.id); approvals += 1
            } else { chat.declineAction(pending.id) }
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    defer { chat.stop() }
    #expect(!chat.running)
    #expect(chat.error == nil)
    #expect(approvals == 1)
    #expect(try await controller.webView.evaluateJavaScript("document.querySelector('#activate').textContent") as? String == "Activated")
}
