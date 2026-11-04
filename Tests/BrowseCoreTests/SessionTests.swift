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
    guard case .split(_, .vertical, _, let top, let lower) = tab.layout,
          case .split(_, .horizontal, _, let left, let right) = top else {
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
    guard case .split(_, _, let fraction, _, _) = layout.resizing(id, to: 4) else { Issue.record("Missing split"); return }
    #expect(fraction == 0.85)
    guard case .split(_, _, let fraction, _, _) = layout.resizing(id, to: -1) else { Issue.record("Missing split"); return }
    #expect(fraction == 0.15)
    #expect(layout.resizing(UUID(), to: 0.2) == layout)
}

// @lat: [[tests#Address resolution]]
@Test func addresses() {
    #expect(AddressResolver.resolve(" example.com/path ")?.absoluteString == "https://example.com/path")
    #expect(AddressResolver.resolve("localhost:8080")?.absoluteString == "http://localhost:8080")
    #expect(AddressResolver.resolve("https://swift.org")?.host == "swift.org")
    #expect(AddressResolver.resolve("browse://start")?.scheme == "browse")
    #expect(AddressResolver.resolve("file:///etc/passwd") == nil)
    #expect(AddressResolver.resolve("javascript://alert(1)") == nil)
    #expect(AddressResolver.resolve("   ") == nil)
    let query = AddressResolver.resolve("swift ui & webkit")!
    #expect(URLComponents(url: query, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "swift ui & webkit")
}
