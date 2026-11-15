import AppKit
import SwiftUI
import BrowseCore

struct FloatingPanelBackground: View {
    var appearance: GlassAppearance = .floatingPanelDefault
    var body: some View {
        FloatingPanelGlass(appearance: appearance)
            .overlay {
                RoundedRectangle(cornerRadius: 12).fill(.black.opacity(appearance.darkening))
                    .allowsHitTesting(false)
            }
    }
}

private struct FloatingPanelGlass: NSViewRepresentable {
    var appearance: GlassAppearance
    func makeNSView(context: Context) -> FloatingPanelGlassView { FloatingPanelGlassView() }
    func updateNSView(_ view: FloatingPanelGlassView, context: Context) {
        view.style = appearance.clear ? .clear : .regular
        view.tintColor = appearance.tint?.nsColor
    }
}

final class FloatingPanelGlassView: NSGlassEffectView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        cornerRadius = 12
        style = .regular
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // Empty panel space must not activate links or tabs underneath it.
    // Foreground controls keep their normal native hit testing.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return !isHiddenOrHasHiddenAncestor && NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).contains(local) ? self : nil
    }
    override func mouseDown(with event: NSEvent) {}
}
