import Foundation
import Testing
@testable import BrowseCore

// @lat: [[tests#Equal automatic pane sizes]]
@Test(arguments: [SplitAxis.horizontal, .vertical])
func equalAutomaticPaneSizes(axis: SplitAxis) throws {
    var tab = BrowserTab()
    let viewport = CGSize(width: 2400, height: 1800)
    for count in 2...5 {
        // Alternate between nesting at the beginning and end of the row/column.
        tab.split(axis: axis, after: count.isMultiple(of: 2) ? tab.layout.paneIDs.first : tab.layout.paneIDs.last)
        let geometry = PaneGeometry(layout: tab.layout, viewport: viewport)
        let expected = ((axis == .horizontal ? viewport.width : viewport.height) - CGFloat(count - 1) * 6) / CGFloat(count)
        #expect(geometry.panes.count == count)
        for pane in geometry.panes {
            #expect(abs((axis == .horizontal ? pane.frame.width : pane.frame.height) - expected) < 0.001)
        }
    }
    let removed = tab.layout.paneIDs[2]
    let previous = tab.layout
    tab.closePane(removed)
    let reduced = PaneGeometry(layout: tab.layout, viewport: viewport)
    let expected = ((axis == .horizontal ? viewport.width : viewport.height) - 18) / 4
    for pane in reduced.panes {
        #expect(abs((axis == .horizontal ? pane.frame.width : pane.frame.height) - expected) < 0.001)
    }
    #expect(tab.layout.restoring(removed, from: previous) == previous)
    let restored = try JSONDecoder().decode(BrowserTab.self, from: JSONEncoder().encode(tab))
    #expect(PaneGeometry(layout: restored.layout, viewport: viewport).panes.map(\.frame) == reduced.panes.map(\.frame))

    // A perpendicular subdivision remains one column within the surrounding row.
    var mixed = BrowserTab(pages: [Page(), Page()])
    mixed.split(axis: .vertical, after: mixed.pages[1].id)
    mixed.split(axis: .vertical)
    let grid = PaneGeometry(layout: mixed.layout, viewport: viewport)
    #expect(grid.panes[0].frame == CGRect(x: 0, y: 0, width: 1197, height: 1800))
    for pane in grid.panes.dropFirst() {
        #expect(abs(pane.frame.width - 1197) < 0.001)
        #expect(abs(pane.frame.height - 596) < 0.001)
    }
}

// @lat: [[tests#Equal pane sizes after transfers]]
@Test func equalPaneSizesAfterTransfers() throws {
    let viewport = CGSize(width: 2400, height: 1800)
    for edge in PaneDropEdge.allCases {
        let source = BrowserTab()
        var destination = BrowserTab()
        destination.split(axis: edge.axis)
        var session = BrowserSession()
        session.workspaces = [Workspace(name: "Tabs", tabs: [source, destination])]
        session.selectedTab = source.id
        let transferred = session.transferPane(source.focusedPane, from: source.id,
            beside: destination.focusedPane, in: destination.id, edge: edge)
        #expect(transferred)
        let tab = try #require(session.workspaces[0].tabs.first { $0.id == destination.id })
        let geometry = PaneGeometry(layout: tab.layout, viewport: viewport)
        let expected: CGFloat = edge.axis == .horizontal ? 796 : 596
        for pane in geometry.panes {
            #expect(abs((edge.axis == .horizontal ? pane.frame.width : pane.frame.height) - expected) < 0.001)
        }
        let moved = try #require(tab.layout.moving(tab.layout.paneIDs[0], beside: tab.layout.paneIDs[2], edge: edge))
        for pane in PaneGeometry(layout: moved, viewport: viewport).panes {
            #expect(abs((edge.axis == .horizontal ? pane.frame.width : pane.frame.height) - expected) < 0.001)
        }
    }
    // A sidebar tab drop joins complete trees while equalizing their untouched row.
    let source = BrowserTab(), destination = BrowserTab(pages: [Page(), Page()])
    var session = BrowserSession()
    session.workspaces = [Workspace(name: "Tabs", tabs: [source, destination])]
    session.selectedTab = source.id
    let merged = session.joinTabs(source.id, into: destination.id)
    #expect(merged)
    let joined = try #require(session.workspaces[0].tabs.first)
    for pane in PaneGeometry(layout: joined.layout, viewport: viewport).panes {
        #expect(abs(pane.frame.width - 796) < 0.001)
    }
}

// @lat: [[tests#Manual pane sizing intent]]
@Test func manualPaneSizingIntent() throws {
    let viewport = CGSize(width: 2400, height: 1800)
    var tab = BrowserTab(pages: [Page(), Page(), Page()])
    let before = PaneGeometry(layout: tab.layout, viewport: viewport)
    let inner = try #require(before.dividers.last)
    tab.layout = tab.layout.resizing(inner.id, to: inner.fraction(forLength: inner.firstLength + 60), geometry: before)
    let after = PaneGeometry(layout: tab.layout, viewport: viewport)
    // Taking over an automatic tree must not move its other boundaries.
    #expect(after.panes[2].frame == before.panes[2].frame)
    #expect(abs(after.panes[0].frame.width - before.panes[0].frame.width - 60) < 0.001)
    #expect(abs(after.panes[1].frame.width - before.panes[1].frame.width + 60) < 0.001)
    tab.split(axis: .horizontal, after: tab.pages[0].id)
    let inserted = PaneGeometry(layout: tab.layout, viewport: viewport)
    #expect(inserted.panes.first { $0.id == tab.pages[2].id }?.frame == after.panes[2].frame)
    #expect(inserted.panes.first { $0.id == tab.pages[1].id }?.frame == after.panes[1].frame)

    // Resizing back to 50/50 still expresses manual intent after a restart.
    var equal = BrowserTab(pages: [Page(), Page()])
    let geometry = PaneGeometry(layout: equal.layout, viewport: viewport)
    let divider = try #require(geometry.dividers.first)
    equal.layout = equal.layout.resizing(divider.id, to: 0.6, geometry: geometry)
    equal.layout = equal.layout.resizing(divider.id, to: 0.5)
    equal = try JSONDecoder().decode(BrowserTab.self, from: JSONEncoder().encode(equal))
    #expect(!equal.layout.usesAutomaticSizing)
    let original = PaneGeometry(layout: equal.layout, viewport: viewport).panes[0].frame
    equal.split(axis: .horizontal, after: equal.pages[1].id)
    #expect(PaneGeometry(layout: equal.layout, viewport: viewport).panes[0].frame == original)
}

// @lat: [[tests#Legacy pane sizing migration]]
@Test func legacyPaneSizingMigration() throws {
    let a = UUID(), b = UUID(), c = UUID()
    for fraction in [0.5, 0.4] {
        let legacy = PaneLayout.split(id: UUID(), axis: .horizontal, fraction: fraction, first: .pane(a), second: .pane(b))
        let data = try JSONEncoder().encode(legacy)
        #expect(!String(decoding: data, as: UTF8.self).contains("isAutomatic"))
        let decoded = try JSONDecoder().decode(PaneLayout.self, from: data)
        let layout = try #require(decoded.inserting(c, beside: b, edge: .right))
        let geometry = PaneGeometry(layout: layout, viewport: CGSize(width: 2400, height: 1800))
        #expect(abs(geometry.panes[0].frame.width - (fraction == 0.5 ? 796 : 957.6)) < 0.001)
    }
}
