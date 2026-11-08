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

    public enum Style: String, Codable, Sendable { case regular, clear, solid }

    public var style: Style
    public var solidColor: Tint
    public static let defaultSolidColor = Tint(red: 0.18, green: 0.18, blue: 0.18)
    public var clear: Bool {
        get { style == .clear }
        set { style = newValue ? .clear : .regular }
    }
    public var tint: Tint?
    public var darkening: Double

    public init(clear: Bool = false, tint: Tint? = nil, darkening: Double = 0, solidColor: Tint? = nil) {
        style = solidColor != nil ? .solid : (clear ? .clear : .regular)
        self.solidColor = solidColor ?? Self.defaultSolidColor
        self.tint = tint; self.darkening = darkening
    }

    private enum CodingKeys: String, CodingKey { case style, clear, tint, darkening, solidColor }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        style = try values.decodeIfPresent(Style.self, forKey: .style)
            ?? (values.decodeIfPresent(Bool.self, forKey: .clear) == true ? .clear : .regular)
        tint = try values.decodeIfPresent(Tint.self, forKey: .tint)
        darkening = try values.decode(Double.self, forKey: .darkening)
        solidColor = try values.decodeIfPresent(Tint.self, forKey: .solidColor) ?? Self.defaultSolidColor
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(style, forKey: .style)
        try values.encode(clear, forKey: .clear)
        try values.encodeIfPresent(tint, forKey: .tint)
        try values.encode(darkening, forKey: .darkening)
        try values.encode(solidColor, forKey: .solidColor)
    }

    public static let windowDefault = GlassAppearance(darkening: 0.4)
    public static let headerDefault = GlassAppearance(darkening: 0.5)

    public func normalized(defaultDarkening: Double) -> Self {
        func unit(_ value: Double) -> Double { min(1, max(0, value)) }
        var result = self
        result.darkening = darkening.isFinite ? unit(darkening) : defaultDarkening
        if let tint {
            result.tint = [tint.red, tint.green, tint.blue].allSatisfy(\.isFinite)
                ? Tint(red: unit(tint.red), green: unit(tint.green), blue: unit(tint.blue)) : nil
        }
        result.solidColor = [solidColor.red, solidColor.green, solidColor.blue].allSatisfy(\.isFinite)
            ? Tint(red: unit(solidColor.red), green: unit(solidColor.green), blue: unit(solidColor.blue))
            : Self.defaultSolidColor
        return result
    }
}
