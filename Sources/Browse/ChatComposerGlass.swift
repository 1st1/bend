import AppKit
import SwiftUI

// @lat: [[lat.md/architecture/ai#Transcript scrolling]]
struct ChatComposerGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> ChatComposerGlassView { ChatComposerGlassView() }
    func updateNSView(_ view: ChatComposerGlassView, context: Context) {}
}

final class ChatComposerGlassView: NSGlassEffectView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        cornerRadius = 12
        style = .clear
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // Empty composer space must not activate a transcript link underneath it.
    // Foreground editing and send controls keep their normal native hit testing.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return !isHiddenOrHasHiddenAncestor && NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).contains(local) ? self : nil
    }
    override func mouseDown(with event: NSEvent) {}
}
