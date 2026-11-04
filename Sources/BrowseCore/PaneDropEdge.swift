import Foundation
import CoreGraphics

public enum PaneDropEdge: String, CaseIterable, Sendable {
    case left, right, top, bottom

    public var axis: SplitAxis { self == .left || self == .right ? .horizontal : .vertical }
    public var isBefore: Bool { self == .left || self == .top }

    /// Coordinates start at the pane's top left. Normalization makes each edge
    /// reachable even in very wide or tall panes.
    public static func at(_ point: CGPoint, in size: CGSize) -> Self? {
        guard size.width > 0, size.height > 0,
              CGRect(origin: .zero, size: size).contains(point) else { return nil }
        let x = point.x / size.width, y = point.y / size.height
        let distances: [(Self, CGFloat)] = [(.left, x), (.right, 1 - x), (.top, y), (.bottom, 1 - y)]
        return distances.min { $0.1 < $1.1 }?.0
    }

    public func preview(in size: CGSize) -> CGRect {
        switch self {
        case .left: CGRect(x: 0, y: 0, width: size.width / 2, height: size.height)
        case .right: CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height)
        case .top: CGRect(x: 0, y: 0, width: size.width, height: size.height / 2)
        case .bottom: CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)
        }
    }
}
