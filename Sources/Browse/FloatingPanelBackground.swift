import AppKit
import SwiftUI

struct FloatingPanelBackground: View {
    var body: some View {
        FloatingPanelGlass()
            .overlay {
                RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.45))
                    .allowsHitTesting(false)
            }
    }
}

private struct FloatingPanelGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> FloatingPanelGlassView { FloatingPanelGlassView() }
    func updateNSView(_ view: FloatingPanelGlassView, context: Context) {}
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
