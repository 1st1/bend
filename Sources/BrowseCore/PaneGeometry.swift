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

// @lat: [[architecture#Pane layout animation]]
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

    private static func minimumSize(_ layout: PaneLayout) -> CGSize {
        switch layout {
        case .pane: return CGSize(width: 340, height: 240)
        case .split(_, let axis, _, let a, let b):
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
        case .split(let id, let axis, let fraction, let first, let second):
            let horizontal = axis == .horizontal
            let a = Self.minimumSize(first), b = Self.minimumSize(second)
            let available = max(1, (horizontal ? rect.width : rect.height) - Self.gap)
            let minimum = horizontal ? a.width : a.height
            let maximum = max(minimum, available - (horizontal ? b.width : b.height))
            let length = min(max(minimum, available * fraction), maximum)
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
