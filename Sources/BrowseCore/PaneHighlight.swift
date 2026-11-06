import Foundation

public struct PaneHighlight: Codable, Equatable, Sendable {
    public enum Style: String, Codable, Sendable { case none, transparency, outline, glow, titleTint }

    public var style: Style = .none
    public var outlineColor = GlassAppearance.Tint(red: 0.35, green: 0.65, blue: 1)
    public var outlineWidth: Double = 2
    public var glowColor = GlassAppearance.Tint(red: 0.35, green: 0.65, blue: 1)
    public var glowIntensity: Double = 0.6
    public var glowSpread: Double = 8
    public var titleTintColor = GlassAppearance.Tint(red: 0.35, green: 0.65, blue: 1)
    public var titleTintIntensity: Double = 0.3

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case style, outlineColor, outlineWidth, glowColor, glowIntensity, glowSpread, titleTintColor, titleTintIntensity
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        style = try values.decodeIfPresent(Style.self, forKey: .style) ?? style
        outlineColor = try values.decodeIfPresent(GlassAppearance.Tint.self, forKey: .outlineColor) ?? outlineColor
        outlineWidth = try values.decodeIfPresent(Double.self, forKey: .outlineWidth) ?? outlineWidth
        glowColor = try values.decodeIfPresent(GlassAppearance.Tint.self, forKey: .glowColor) ?? glowColor
        glowIntensity = try values.decodeIfPresent(Double.self, forKey: .glowIntensity) ?? glowIntensity
        // Preserve the former intensity-derived spread in existing sessions.
        glowSpread = try values.decodeIfPresent(Double.self, forKey: .glowSpread) ?? (2 + 8 * glowIntensity)
        titleTintColor = try values.decodeIfPresent(GlassAppearance.Tint.self, forKey: .titleTintColor) ?? titleTintColor
        titleTintIntensity = try values.decodeIfPresent(Double.self, forKey: .titleTintIntensity) ?? titleTintIntensity
    }

    public func normalized() -> Self {
        let defaults = Self()
        var result = self
        result.outlineWidth = outlineWidth.isFinite ? min(6, max(0.5, outlineWidth)) : defaults.outlineWidth
        result.glowIntensity = glowIntensity.isFinite ? min(1, max(0, glowIntensity)) : defaults.glowIntensity
        result.glowSpread = glowSpread.isFinite ? min(24, max(0, glowSpread)) : defaults.glowSpread
        result.outlineColor = GlassAppearance(tint: outlineColor).normalized(defaultDarkening: 0).tint ?? defaults.outlineColor
        result.glowColor = GlassAppearance(tint: glowColor).normalized(defaultDarkening: 0).tint ?? defaults.glowColor
        result.titleTintIntensity = titleTintIntensity.isFinite ? min(1, max(0, titleTintIntensity)) : defaults.titleTintIntensity
        result.titleTintColor = GlassAppearance(tint: titleTintColor).normalized(defaultDarkening: 0).tint ?? defaults.titleTintColor
        return result
    }
}
