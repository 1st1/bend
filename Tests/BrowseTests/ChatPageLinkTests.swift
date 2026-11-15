import AppKit
import BrowseCore
import Testing
import Markdown
@testable import Browse

// @lat: [[lat.md/tests/ai-tests#Page citation routing]]
@Test @MainActor func chatPageCitationRouting() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AICitations-\(UUID())")
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    defer { store.stopWindow(); try? FileManager.default.removeItem(at: root) }
    let first = Page(address: "https://example.com/article?q=a+b")
    let second = Page(address: "https://example.com/article?q=a+b")
    let other = Page(address: "https://other.example")
    let tab = BrowserTab(title: "Chat", pages: [first, second])
    let otherTab = BrowserTab(title: "Other", pages: [other])
    store.session.workspaces = [Workspace(name: "Tabs", tabs: [tab, otherTab])]
    store.session.selectedTab = tab.id
    let controller = store.controller(for: second)
    controller.webView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    controller.webView.loadHTMLString("<body><div style='height:2000px'>Top</div><h2 id='50489641'>Referenced comment</h2><div style='height:1000px'></div></body>", baseURL: URL(string: second.address))
    for _ in 0..<200 {
        if controller.webView.url != nil && !controller.webView.isLoading { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    let tools = PaneChatTools(store: store, tabID: tab.id)
    let result = try await tools.execute("read_pane", input: .init(pane: second.id.uuidString))
    guard case .string(let json) = result else { Issue.record("Missing read result"); return }
    let data = try #require(json.data(using: .utf8))
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let refs = try #require(object["references"] as? [[String: String]])
    let link = try #require(refs.first(where: { $0["label"] == "Referenced comment" })?["citation"])
    #expect(!link.contains("selector="))
    let rendered = ChatMarkdownText.inline(Document(parsing: "[Comment](\(link))"))
    let citationURL = try #require(rendered.runs.compactMap(\.link).first)
    let parsed = try #require(ChatPageLinks.citationComponents(citationURL))
    #expect(parsed.queryItems?.first(where: { $0.name == "url" })?.value == second.address + "#50489641")
    try await ChatPageLinks.open(citationURL, tabID: tab.id, store: store)
    #expect(store.selectedTab.focusedPane == second.id)
    for _ in 0..<100 {
        if controller.webView.url?.fragment == "50489641" { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(controller.webView.url?.fragment == "50489641")
    #expect(store.selectedTab.pages.count == 2)
    var malformed = try #require(URLComponents(string: link))
    malformed.queryItems = [URLQueryItem(name: "url", value: second.address), URLQueryItem(name: "selector", value: "[")]
    malformed.percentEncodedQuery = malformed.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    do {
        try await ChatPageLinks.open(try #require(malformed.url), tabID: tab.id, store: store)
        Issue.record("Invalid selector should fail")
    } catch {
        #expect(error is ChatPageLinks.LinkError)
    }
    let foreign = try #require(URL(string: ChatPageLinks.citation(pane: other.id, address: other.address)))
    await #expect(throws: Error.self) { try await ChatPageLinks.open(foreign, tabID: tab.id, store: store) }
    try await ChatPageLinks.open(URL(string: "https://external.example/source")!, tabID: tab.id, store: store)
    #expect(store.selectedTab.pages.count == 3)
    #expect(store.selectedTab.pages.last?.address == "https://external.example/source")
    #expect(store.session.workspaces[0].tabs[1].pages.count == 1)

    // A stale reference has an unambiguous destination when only one pane remains.
    let sole = store.controller(for: other)
    let webView = sole.webView
    let destination = "https://example.com/source?q=a+b#details"
    let stale = try #require(URL(string: ChatPageLinks.citation(pane: UUID(), address: destination)))
    try await ChatPageLinks.open(stale, tabID: otherTab.id, store: store)
    #expect(store.selectedTab.id == otherTab.id && store.selectedTab.focusedPane == other.id)
    #expect(store.selectedTab.pages.count == 1 && sole.webView === webView)
    #expect(sole.address == destination)
    #expect(store.session.workspaces[0].tabs[0].pages.count == 3)

    let external = URL(string: "https://external.example/another-source")!
    try await ChatPageLinks.open(external, tabID: otherTab.id, store: store)
    #expect(sole.address == external.absoluteString && store.selectedTab.pages.count == 1)
    #expect(sole.webView === webView)

    // Falling back changes only the destination pane, not the allowed URL formats.
    for address in ["file:///etc/passwd", "javascript:alert(1)", "https://user:secret@example.com/"] {
        let unsafe = try #require(URL(string: ChatPageLinks.citation(pane: UUID(), address: address)))
        await #expect(throws: Error.self) { try await ChatPageLinks.open(unsafe, tabID: otherTab.id, store: store) }
    }
    var legacy = try #require(URLComponents(url: stale, resolvingAgainstBaseURL: false))
    legacy.queryItems?.append(URLQueryItem(name: "selector", value: "#details"))
    await #expect(throws: Error.self) { try await ChatPageLinks.open(try #require(legacy.url), tabID: otherTab.id, store: store) }
    #expect(sole.address == external.absoluteString && store.selectedTab.pages.count == 1)

    // A designated link pane also provides an explicit fallback in a split tab.
    store.session.workspaces[0].tabs[0].commandClickPaneID = second.id
    let designatedWebView = controller.webView
    let untouched = store.controller(for: first).address
    try await ChatPageLinks.open(stale, tabID: tab.id, store: store)
    #expect(store.selectedTab.id == tab.id && store.selectedTab.focusedPane == second.id)
    #expect(controller.address == destination && controller.webView === designatedWebView)
    try await ChatPageLinks.open(external, tabID: tab.id, store: store)
    #expect(controller.address == external.absoluteString && store.selectedTab.pages.count == 3)
    #expect(store.selectedTab.commandClickPaneID == second.id)
    #expect(store.controller(for: first).address == untouched)
    #expect(sole.address == external.absoluteString)

    // A citation whose original pane still exists keeps its exact target.
    let exact = try #require(URL(string: ChatPageLinks.citation(pane: first.id, address: destination)))
    try await ChatPageLinks.open(exact, tabID: tab.id, store: store)
    #expect(store.selectedTab.focusedPane == first.id)
    #expect(store.controller(for: first).address == destination && controller.address == external.absoluteString)
}
