import AppKit
import SwiftUI
import Combine
import BrowseCore

extension GlassAppearance.Tint {
    var color: Color { Color(nsColor: nsColor) }
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }

    init?(color: Color) {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        self.init(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
    }
}

@available(macOS 26.0, *)
extension GlassAppearance {
    var material: Glass { (clear ? Glass.clear : .regular).tint(tint?.color) }
}

@available(macOS 26.0, *)
@MainActor
final class BrowserWindowGlass: NSGlassEffectView {
    private var observation: AnyCancellable?

    init(store: BrowserStore, content: NSView) {
        super.init(frame: .zero)
        // The window supplies outer clipping; its content owns the darkening
        // background so foreground controls and websites remain undimmed.
        cornerRadius = 0
        contentView = content
        observation = store.preferencesStore.$session.map { ($0.windowGlass ?? .windowDefault).normalized(defaultDarkening: 0) }
            .removeDuplicates().sink { [weak self] appearance in
                self?.style = appearance.clear ? .clear : .regular
                self?.tintColor = appearance.tint?.nsColor
            }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// Both native and SwiftUI headers use these opaque sRGB gradient endpoints.
extension GlassAppearance.Tint {
    var headerGradientTop: Self {
        Self(red: red + (1 - red) * 0.04, green: green + (1 - green) * 0.04, blue: blue + (1 - blue) * 0.04)
    }
    var headerGradientBottom: Self {
        Self(red: red * 0.94, green: green * 0.94, blue: blue * 0.94)
    }
}

final class SolidHeaderBackground: NSView {
    var color = GlassAppearance.defaultSolidColor { didSet { needsDisplay = true } }
    override var isOpaque: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSGradient(starting: color.headerGradientBottom.nsColor, ending: color.headerGradientTop.nsColor)?
            .draw(in: bounds, angle: 90)
    }
}
