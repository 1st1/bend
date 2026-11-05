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
