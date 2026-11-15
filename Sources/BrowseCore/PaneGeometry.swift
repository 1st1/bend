import Foundation
import CoreGraphics

public struct PanePlacement: Identifiable {
    public let id: UUID
    public let frame: CGRect
    public let insertionAxis: SplitAxis
}

public struct DividerPlacement: Identifiable {
    public let id: UUID
    public let axis: SplitAxis
    public let frame: CGRect
    public let firstLength: CGFloat
    public let available: CGFloat
    public let minimum: CGFloat
    public let maximum: CGFloat

    public func fraction(forLength length: CGFloat) -> Double {
        Double(min(max(minimum, length), maximum) / available)
    }
}

// @lat: [[lat.md/architecture/pane-layout#Pane layout animation]]
public struct PaneGeometry {
    public static let gap: CGFloat = 6
    public let size: CGSize
    public private(set) var panes: [PanePlacement] = []
    public private(set) var dividers: [DividerPlacement] = []

    public init(layout: PaneLayout, viewport: CGSize) {
        let minimum = Self.minimumSize(layout)
        size = CGSize(width: max(minimum.width, viewport.width), height: max(minimum.height, viewport.height))
        place(layout, in: CGRect(origin: .zero, size: size), insertionAxis: .horizontal)
    }

    /// Panes whose visible region is too small to host a page.
    public func clippedPaneIDs(in viewport: CGSize) -> [UUID] {
        panes.filter {
            let frame = $0.frame.intersection(CGRect(origin: .zero, size: viewport))
            return frame.isNull || frame.width < 339.5 || frame.height < 239.5
        }.map(\.id)
    }

    public struct OverflowRegion: Identifiable {
        public var id: UUID { paneIDs[0] }
        public var paneIDs: [UUID]
        public let frame: CGRect
    }

    /// Coalesce hidden subtrees, keeping neighboring usable panes visible.
    public func overflowRegions(layout: PaneLayout, in viewport: CGSize) -> [OverflowRegion] {
        let hidden = Set(clippedPaneIDs(in: viewport))
        let visible = CGRect(origin: .zero, size: viewport)
        func ids(_ node: PaneLayout) -> [UUID] {
            switch node {
            case .pane(let id): return [id]
            case .split(_, _, _, let a, let b, _): return ids(a) + ids(b)
            }
        }
        func regions(_ node: PaneLayout) -> [OverflowRegion] {
            let members = ids(node)
            if members.allSatisfy(hidden.contains) {
                let bounds = panes.filter { members.contains($0.id) }.reduce(CGRect.null) { $0.union($1.frame) }
                return [OverflowRegion(paneIDs: members, frame: bounds.intersection(visible))]
            }
            if case .split(_, _, _, let a, let b, _) = node { return regions(a) + regions(b) }
            return []
        }
        let all = regions(layout)
        var result = all.filter { !$0.frame.isNull && !$0.frame.isEmpty }
        // Fully offscreen siblings still need a reachable recovery action.
        let offscreen = all.filter { $0.frame.isNull || $0.frame.isEmpty }.flatMap(\.paneIDs)
        if !offscreen.isEmpty, !result.isEmpty { result[result.count - 1].paneIDs += offscreen }
        return result
    }

    private static func minimumSize(_ layout: PaneLayout) -> CGSize {
        switch layout {
        case .pane: return CGSize(width: 340, height: 240)
        case .split(_, let axis, _, let a, let b, _):
            let first = minimumSize(a), second = minimumSize(b)
            return axis == .horizontal
                ? CGSize(width: first.width + second.width + gap, height: max(first.height, second.height))
                : CGSize(width: max(first.width, second.width), height: first.height + second.height + gap)
        }
    }

    private mutating func place(_ layout: PaneLayout, in rect: CGRect, insertionAxis: SplitAxis) {
        switch layout {
        case .pane(let id):
            panes.append(PanePlacement(id: id, frame: rect, insertionAxis: insertionAxis))
        case .split(let id, let axis, let fraction, let first, let second, _):
            let horizontal = axis == .horizontal
            let a = Self.minimumSize(first), b = Self.minimumSize(second)
            let available = max(1, (horizontal ? rect.width : rect.height) - Self.gap)
            let minimum = horizontal ? a.width : a.height
            let maximum = max(minimum, available - (horizontal ? b.width : b.height))
            let firstUnits = CGFloat(first.automaticUnits(along: axis))
            let secondUnits = CGFloat(second.automaticUnits(along: axis))
            // Internal gaps belong to their subtree, not to a pane's equal share.
            let paneSpace = available - Self.gap * (firstUnits + secondUnits - 2)
            let automaticLength = paneSpace * firstUnits / (firstUnits + secondUnits) + Self.gap * (firstUnits - 1)
            let desired = layout.usesAutomaticSizing ? automaticLength : available * fraction
            let length = min(max(minimum, desired), maximum)
            var firstRect = rect, secondRect = rect, dividerRect = rect
            if horizontal {
                firstRect.size.width = length
                dividerRect.origin.x += length
                dividerRect.size.width = Self.gap
                secondRect.origin.x += length + Self.gap
                secondRect.size.width = available - length
            } else {
                firstRect.size.height = length
                dividerRect.origin.y += length
                dividerRect.size.height = Self.gap
                secondRect.origin.y += length + Self.gap
                secondRect.size.height = available - length
            }
            dividers.append(DividerPlacement(id: id, axis: axis, frame: dividerRect,
                firstLength: length, available: available, minimum: minimum, maximum: maximum))
            place(first, in: firstRect, insertionAxis: insertionAxis)
            place(second, in: secondRect, insertionAxis: axis)
        }
    }
}
