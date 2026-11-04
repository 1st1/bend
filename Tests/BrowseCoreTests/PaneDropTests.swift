import Foundation
import CoreGraphics
import Testing
@testable import BrowseCore

// @lat: [[tests#Pane drop layout moves]]
@Test func paneDropLayoutMoves() throws {
    let a = UUID(), b = UUID(), c = UUID(), d = UUID()
    let siblingID = UUID()
    let layout = PaneLayout.split(id: UUID(), axis: .horizontal, fraction: 0.4,
        first: .split(id: UUID(), axis: .vertical, fraction: 0.3, first: .pane(a), second: .pane(b)),
        second: .split(id: siblingID, axis: .vertical, fraction: 0.7, first: .pane(c), second: .pane(d)))
    for source in layout.paneIDs {
        for target in layout.paneIDs where source != target {
            for edge in PaneDropEdge.allCases {
                let moved = try #require(layout.moving(source, beside: target, edge: edge))
                #expect(moved.paneIDs.count == 4)
                #expect(Set(moved.paneIDs) == Set(layout.paneIDs))
                let geometry = PaneGeometry(layout: moved, viewport: CGSize(width: 2000, height: 1500))
                let from = try #require(geometry.panes.first { $0.id == source }?.frame)
                let to = try #require(geometry.panes.first { $0.id == target }?.frame)
                switch edge {
                case .left: #expect(from.maxX + 6 == to.minX && from.minY == to.minY && from.height == to.height)
                case .right: #expect(to.maxX + 6 == from.minX && from.minY == to.minY && from.height == to.height)
                case .top: #expect(from.maxY + 6 == to.minY && from.minX == to.minX && from.width == to.width)
                case .bottom: #expect(to.maxY + 6 == from.minY && from.minX == to.minX && from.width == to.width)
                }
            }
        }
    }
    let moved = try #require(layout.moving(a, beside: b, edge: .right))
    guard case .split(_, .horizontal, let fraction, _, let sibling) = moved else {
        Issue.record("An unrelated split must survive the move"); return
    }
    #expect(fraction == 0.4)
    #expect(sibling == .split(id: siblingID, axis: .vertical, fraction: 0.7, first: .pane(c), second: .pane(d)))
    #expect(layout.moving(a, beside: a, edge: .left) == nil)
    #expect(layout.moving(UUID(), beside: a, edge: .left) == nil)
    #expect(layout.moving(a, beside: UUID(), edge: .left) == nil)
    #expect(PaneLayout.pane(a).moving(a, beside: a, edge: .top) == nil)
}

// @lat: [[tests#Pane drop targeting]]
@Test func paneDropTargeting() {
    let size = CGSize(width: 1000, height: 400)
    #expect(PaneDropEdge.at(CGPoint(x: 20, y: 200), in: size) == .left)
    #expect(PaneDropEdge.at(CGPoint(x: 980, y: 200), in: size) == .right)
    #expect(PaneDropEdge.at(CGPoint(x: 500, y: 10), in: size) == .top)
    #expect(PaneDropEdge.at(CGPoint(x: 500, y: 390), in: size) == .bottom)
    #expect(PaneDropEdge.at(CGPoint(x: -1, y: 100), in: size) == nil)
    #expect(PaneDropEdge.at(.zero, in: .zero) == nil)
    #expect(PaneDropEdge.top.preview(in: size) == CGRect(x: 0, y: 0, width: 1000, height: 200))
    #expect(PaneDropEdge.bottom.preview(in: size) == CGRect(x: 0, y: 200, width: 1000, height: 200))
    #expect(PaneDropEdge.left.preview(in: size) == CGRect(x: 0, y: 0, width: 500, height: 400))
    #expect(PaneDropEdge.right.preview(in: size) == CGRect(x: 500, y: 0, width: 500, height: 400))
}
