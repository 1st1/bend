import AppKit
import SwiftUI

// @lat: [[lat.md/architecture/ai#Transcript scrolling]]
struct ChatHeaderGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> ChatHeaderGlassView { ChatHeaderGlassView() }
    func updateNSView(_ view: ChatHeaderGlassView, context: Context) {}
}

final class ChatHeaderGlassView: NSGlassEffectView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        cornerRadius = 0
        style = .regular
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // The native header buttons live above the toolbar. This shield prevents
    // clicks elsewhere on the glass from reaching links scrolling underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        !isHiddenOrHasHiddenAncestor && bounds.contains(convert(point, from: superview)) ? self : nil
    }
    override func mouseDown(with event: NSEvent) {}
}
