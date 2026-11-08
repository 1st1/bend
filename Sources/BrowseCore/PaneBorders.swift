import Foundation

public struct PaneBorders: Codable, Equatable, Sendable {
    public struct Line: Codable, Equatable, Sendable {
        public var enabled = true
        public var color: GlassAppearance.Tint
        public var opacity: Double
        public var width: Double = 0.5

        public var visibleWidth: Double { enabled ? width : 0 }

        fileprivate func normalized(defaults: Self) -> Self {
            var result = self
            result.width = width.isFinite ? min(4, max(0.5, width)) : defaults.width
            result.opacity = opacity.isFinite ? min(1, max(0, opacity)) : defaults.opacity
            result.color = GlassAppearance(tint: color).normalized(defaultDarkening: 0).tint ?? defaults.color
            return result
        }
    }

    public var separator = Line(color: .init(red: 1, green: 1, blue: 1), opacity: 0.06)

    public init() {}

    public func normalized() -> Self {
        let defaults = Self()
        var result = self
        result.separator = separator.normalized(defaults: defaults.separator)
        return result
    }
}
