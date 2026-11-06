import SwiftUI
import BrowseCore

// Outside the native pane clip so the glow can extend into the pane gutter.
// This is decorative only; callers disable hit testing and accessibility.
struct PaneHighlightOverlay: View {
    let appearance: PaneHighlight
    let focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            switch appearance.style {
            case .transparency, .titleTint:
                Color.clear
            case .outline:
                RoundedRectangle(cornerRadius: 12 + appearance.outlineWidth + 1 / max(1, displayScale), style: .continuous)
                    .strokeBorder(appearance.outlineColor.color, lineWidth: appearance.outlineWidth)
            case .glow:
                ZStack {
                    if appearance.glowSpread > 0 {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(appearance.glowColor.color, lineWidth: max(2, appearance.glowSpread * 0.6))
                            .blur(radius: appearance.glowSpread)
                    }
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(appearance.glowColor.color, lineWidth: 2)
                }
                .opacity(appearance.glowIntensity)
            }
        }
        .opacity(focused ? 1 : 0)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.1), value: focused)
    }
}
