import SwiftUI
import BrowseCore

// Only the outline is drawn over the pane. Glow is part of the window's shadow
// layer so it cannot bleed inward or be clipped by the pane canvas.
struct PaneHighlightOverlay: View {
    let appearance: PaneHighlight
    let focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            switch appearance.style {
            case .transparency, .titleTint, .glow:
                Color.clear
            case .outline:
                RoundedRectangle(cornerRadius: 12 + appearance.outlineWidth + 1 / max(1, displayScale), style: .continuous)
                    .strokeBorder(appearance.outlineColor.color, lineWidth: appearance.outlineWidth)
            }
        }
        .opacity(focused ? 1 : 0)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.1), value: focused)
    }
}
