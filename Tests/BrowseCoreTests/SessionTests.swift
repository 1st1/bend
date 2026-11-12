import Foundation
import Testing
@testable import BrowseCore

// @lat: [[tests#Nested splits and closing]]
@Test func nestedSplitsAndClosing() {
    var tab = BrowserTab()
    let original = tab.focusedPane
    tab.split(axis: .horizontal)
    let right = tab.focusedPane
    tab.split(axis: .vertical)
    let bottom = tab.focusedPane
    #expect(tab.layout.paneIDs == [original, right, bottom])
    tab.closePane(right)
    #expect(tab.layout.paneIDs == [original, bottom])
    #expect(tab.focusedPane == bottom)
    tab.closePane(bottom)
    #expect(tab.layout == .pane(original))
    #expect(tab.focusedPane == original)
    tab.closePane(original)
    #expect(tab.pages.count == 1)
    #expect(tab.layout == .pane(original))
}

// @lat: [[tests#Link pane placement]]
@Test func linkPanePlacement() throws {
    var tab = BrowserTab()
    let source = tab.focusedPane
    tab.split(axis: .vertical)
    let bottom = tab.focusedPane
    let destination = "https://example.com/target?q=one#section"
    tab.split(axis: .horizontal, after: source, address: destination)
    let opened = tab.focusedPane
    #expect(tab.layout.paneIDs == [source, opened, bottom])
    #expect(tab.pages.first { $0.id == opened }?.address == destination)
    #expect(tab.pages.first { $0.id == source }?.address == "browse://start")
    guard case .split(_, .vertical, _, let top, let lower, _) = tab.layout,
          case .split(_, .horizontal, _, let left, let right, _) = top else {
        Issue.record("Link must split its source pane to the right, preserving the other branch")
        return
    }
    #expect(lower == .pane(bottom))
    #expect(left == .pane(source))
    #expect(right == .pane(opened))
    let restored = try JSONDecoder().decode(BrowserTab.self, from: JSONEncoder().encode(tab))
    #expect(restored.layout == tab.layout)
    #expect(restored.focusedPane == opened)
    #expect(restored.pages.first { $0.id == opened }?.address == destination)
    let layout = tab.layout
    tab.split(axis: .horizontal, after: UUID(), address: destination)
    #expect(tab.layout == layout)
    #expect(tab.pages.count == 3)
    #expect(tab.focusedPane == opened)
}

// @lat: [[tests#Session round trip]]
@Test func sessionRoundTrip() throws {
    var session = BrowserSession()
    session.workspaces[0].tabs[0].split(axis: .vertical)
    let data = try JSONEncoder().encode(session)
    let restored = try JSONDecoder().decode(BrowserSession.self, from: data)
    #expect(restored.isValid)
    #expect(restored.selectedTab == session.selectedTab)
    #expect(restored.workspaces[0].tabs[0].layout == session.workspaces[0].tabs[0].layout)
    session.workspaces[0].tabs[0].pages.removeLast()
    #expect(!session.isValid)
    session = BrowserSession()
    session.selectedTab = UUID()
    #expect(!session.isValid)
}

// @lat: [[tests#Divider bounds]]
@Test func dividerBounds() {
    let id = UUID(), a = UUID(), b = UUID()
    let layout = PaneLayout.split(id: id, axis: .horizontal, fraction: 0.5, first: .pane(a), second: .pane(b))
    guard case .split(_, _, let fraction, _, _, _) = layout.resizing(id, to: 4) else { Issue.record("Missing split"); return }
    #expect(fraction == 0.85)
    guard case .split(_, _, let fraction, _, _, _) = layout.resizing(id, to: -1) else { Issue.record("Missing split"); return }
    #expect(fraction == 0.15)
    #expect(layout.resizing(UUID(), to: 0.2) == layout)
}

// @lat: [[tests#Address resolution]]
@Test func addresses() {
    #expect(AddressResolver.resolve(" example.com/path ")?.absoluteString == "https://example.com/path")
    #expect(AddressResolver.resolve("localhost:8080")?.absoluteString == "http://localhost:8080")
    #expect(AddressResolver.resolve("https://swift.org")?.host == "swift.org")
    #expect(AddressResolver.resolve("browse://start")?.scheme == "browse")
    #expect(AddressResolver.resolve("browse://history")?.absoluteString == "browse://history")
    #expect(AddressResolver.resolve("file:///etc/passwd") == nil)
    #expect(AddressResolver.resolve("javascript://alert(1)") == nil)
    #expect(AddressResolver.resolve("   ") == nil)
    for (engine, host, path) in [(SearchEngine.google, "www.google.com", "/search"),
                                 (.duckDuckGo, "duckduckgo.com", "/"), (.kagi, "kagi.com", "/search")] {
        let text = "C++ & café #swift? 100%"
        let url = AddressResolver.resolve(text, searchEngine: engine)!
        #expect(url.host == host)
        #expect(url.path == path)
        #expect(url.scheme == "https")
        #expect(!url.absoluteString.contains("+"))
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "q", value: text)])
        #expect(AddressResolver.resolve("example.com/path", searchEngine: engine)?.absoluteString == "https://example.com/path")
        #expect(AddressResolver.resolve("browse://start", searchEngine: engine)?.absoluteString == "browse://start")
    }
    let query = AddressResolver.resolve("swift ui & webkit")!
    #expect(URLComponents(url: query, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "swift ui & webkit")
}

// @lat: [[tests#Custom search templates]]
@Test func customSearchTemplates() throws {
    let query = "C++ & café /?=#100%"
    let engine = CustomSearchEngine(name: " My search ", template: " https://example.com/search?q=%s&language=en&fixed=a%2Bb ")
    #expect(engine.name == "My search")
    #expect(engine.validationError == nil)
    let url = try #require(engine.searchURL(for: query))
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(components.queryItems == [URLQueryItem(name: "q", value: query), URLQueryItem(name: "language", value: "en"), URLQueryItem(name: "fixed", value: "a+b")])
    #expect(!url.absoluteString.contains("+"))
    let path = CustomSearchEngine(name: "Path", template: "https://example.com/search/%s?lang=en")
    #expect(path.searchURL(for: "a/b")?.absoluteString == "https://example.com/search/a%2Fb?lang=en")
    for template in ["https://example.com/", "https://example.com/?q=%s&other=%s", "javascript:alert('%s')",
                     "file:///tmp/%s", "https://%s.example.com/", "https://user:pass@example.com/?q=%s",
                     "https://example.com/#%s", "https://example.com/?q=%s&broken=%zz", "https://example.com/a b?q=%s"] {
        let invalid = CustomSearchEngine(name: "Invalid", template: template)
        #expect(invalid.validationError != nil)
        #expect(invalid.searchURL(for: query) == nil)
    }
    #expect(CustomSearchEngine(name: " ", template: engine.template).validationError != nil)
    #expect(AddressResolver.resolve(query, searchEngine: .custom, customSearchEngine: engine) == url)
    #expect(AddressResolver.resolve(query, searchEngine: .custom) == nil)
    #expect(AddressResolver.resolve("example.com", searchEngine: .custom)?.host == "example.com")
}
