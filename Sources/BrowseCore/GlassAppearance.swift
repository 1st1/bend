import Foundation

public struct GlassAppearance: Codable, Equatable, Sendable {
    public struct Tint: Codable, Equatable, Sendable {
        public var red: Double
        public var green: Double
        public var blue: Double

        public init(red: Double, green: Double, blue: Double) {
            self.red = red; self.green = green; self.blue = blue
        }
    }

    public var clear: Bool
    public var tint: Tint?
    public var darkening: Double

    public init(clear: Bool = false, tint: Tint? = nil, darkening: Double = 0) {
        self.clear = clear; self.tint = tint; self.darkening = darkening
    }

    public static let windowDefault = GlassAppearance()
    public static let headerDefault = GlassAppearance(darkening: 0.5)

    public func normalized(defaultDarkening: Double) -> Self {
        func unit(_ value: Double) -> Double { min(1, max(0, value)) }
        var result = self
        result.darkening = darkening.isFinite ? unit(darkening) : defaultDarkening
        if let tint {
            result.tint = [tint.red, tint.green, tint.blue].allSatisfy(\.isFinite)
                ? Tint(red: unit(tint.red), green: unit(tint.green), blue: unit(tint.blue)) : nil
        }
        return result
    }
}
