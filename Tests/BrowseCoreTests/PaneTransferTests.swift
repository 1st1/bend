import Foundation
import Testing
@testable import BrowseCore

// @lat: [[tests#Cross-tab pane transfer model]]
@Test func paneTransferModel() throws {
    for edge in PaneDropEdge.allCases {
        let a = Page(address: "https://a.test"), b = Page(address: "https://b.test"), c = Page(address: "https://c.test")
        let source = BrowserTab(pages: [a, b]), destination = BrowserTab(pages: [c])
        var session = BrowserSession()
        session.workspaces = [Workspace(name: "A", tabs: [source]), Workspace(name: "B", tabs: [destination])]
        session.selectedTab = source.id
        let movedA = session.transferPane(a.id, from: source.id, beside: c.id, in: destination.id, edge: edge)
        #expect(movedA)
        #expect(session.isValid)
        #expect(session.selectedTab == destination.id)
        #expect(session.workspaces[0].tabs[0].pages.map(\.id) == [b.id])
        #expect(session.workspaces[0].tabs[0].focusedPane == b.id)
        #expect(session.workspaces[1].tabs[0].layout.paneIDs == (edge.isBefore ? [a.id, c.id] : [c.id, a.id]))
        #expect(session.workspaces[1].tabs[0].pages.last?.address == a.address)
        let movedB = session.transferPane(b.id, from: source.id, beside: c.id, in: destination.id, edge: edge)
        #expect(movedB)
        #expect(session.isValid)
        #expect(!session.workspaces.flatMap(\.tabs).contains { $0.id == source.id })
        #expect(session.workspaces[0].tabs[0].pages[0].address == "browse://start")
        let detachedID = session.detachPane(a.id, from: destination.id, into: session.workspaces[0].id, title: "A")
        let detached = try #require(detachedID)
        #expect(session.selectedTab == detached)
        #expect(session.workspaces[0].tabs.last?.pages.first?.id == a.id)
        #expect(session.workspaces[0].tabs.last?.title == "A")
        #expect(session.isValid)
        let encoded = try JSONEncoder().encode(session)
        let missing = session.transferPane(UUID(), from: destination.id, beside: c.id, in: detached, edge: edge)
        #expect(!missing)
        let same = session.transferPane(c.id, from: destination.id, beside: c.id, in: destination.id, edge: edge)
        #expect(!same)
        let redundant = session.detachPane(a.id, from: detached, into: session.workspaces[0].id, title: "A")
        #expect(redundant == nil)
        let restored = try JSONDecoder().decode(BrowserSession.self, from: encoded)
        #expect(restored.isValid)
        #expect(restored.workspaces.map { $0.tabs.map(\.layout) } == session.workspaces.map { $0.tabs.map(\.layout) })
    }
}
