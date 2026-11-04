import Foundation
import CoreGraphics
import Testing
@testable import BrowseCore

// @lat: [[tests#Pane geometry and insertion]]
@Test func paneGeometryAndInsertion() throws {
    var tab = BrowserTab()
    let original = tab.focusedPane
    let viewport = CGSize(width: 1200, height: 800)
    let before = PaneGeometry(layout: tab.layout, viewport: viewport)
    #expect(before.panes.first?.frame == CGRect(origin: .zero, size: viewport))
    tab.split(axis: .horizontal)
    let right = tab.focusedPane
    let split = PaneGeometry(layout: tab.layout, viewport: viewport)
    #expect(split.panes.map(\.id) == [original, right])
    #expect(split.panes[0].frame == CGRect(x: 0, y: 0, width: 596, height: 800))
    #expect(split.panes[1].frame == CGRect(x: 604, y: 0, width: 596, height: 800))
    #expect(split.panes[1].insertionAxis == .horizontal)
    tab.split(axis: .vertical)
    let bottom = tab.focusedPane
    let nested = PaneGeometry(layout: tab.layout, viewport: viewport)
    #expect(nested.panes.map(\.id) == [original, right, bottom])
    #expect(nested.panes[0].frame == split.panes[0].frame)
    #expect(nested.panes[1].frame == CGRect(x: 604, y: 0, width: 596, height: 396))
    #expect(nested.panes[2].frame == CGRect(x: 604, y: 404, width: 596, height: 396))
    #expect(nested.panes[2].insertionAxis == .vertical)
    tab.closePane(bottom)
    let closed = PaneGeometry(layout: tab.layout, viewport: viewport)
    #expect(closed.panes.map(\.frame) == split.panes.map(\.frame))
}

// @lat: [[tests#Pane geometry bounds]]
@Test func paneGeometryBounds() throws {
    var tab = BrowserTab()
    tab.split(axis: .horizontal)
    tab.split(axis: .vertical)
    let geometry = PaneGeometry(layout: tab.layout, viewport: CGSize(width: 100, height: 100))
    #expect(geometry.size == CGSize(width: 688, height: 488))
    for pane in geometry.panes {
        #expect(pane.frame.width >= 340)
        #expect(pane.frame.height >= 240)
        #expect(CGRect(origin: .zero, size: geometry.size).contains(pane.frame))
    }
    for divider in geometry.dividers {
        #expect(divider.fraction(forLength: -1000) == Double(divider.minimum / divider.available))
        #expect(divider.fraction(forLength: 10000) == Double(divider.maximum / divider.available))
        #expect(divider.axis == .horizontal ? divider.frame.width == 8 : divider.frame.height == 8)
    }
    let wide = PaneGeometry(layout: tab.layout, viewport: CGSize(width: 1600, height: 1000))
    let divider = try #require(wide.dividers.first)
    tab.layout = tab.layout.resizing(divider.id, to: divider.fraction(forLength: 1000))
    let resized = PaneGeometry(layout: tab.layout, viewport: wide.size)
    #expect(abs(resized.panes[0].frame.width - 1000) < 0.001)
    #expect(abs(resized.panes[1].frame.minX - 1008) < 0.001)
}
