import AppKit
import SwiftUI

// Shadows belong to the window background, outside the clipped pane canvases.
struct PaneShadowPlane: NSViewRepresentable {
    func makeNSView(context: Context) -> PaneShadowView { PaneShadowView() }
    func updateNSView(_ view: PaneShadowView, context: Context) { view.needsDisplay = true }
}

final class PaneShadowView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard window != nil else { return }
        for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(geometryChanged(_:)), name: name, object: nil)
        }
        needsDisplay = true
    }

    @objc private func geometryChanged(_ notification: Notification) {
        guard let changed = notification.object as? NSView, changed !== self, changed.window === window else { return }
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let root = window?.contentView, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        var shapes: [(CGPath, CGRect)] = []
        func collect(_ view: NSView) {
            guard !view.isHiddenOrHasHiddenAncestor else { return }
            if let pane = view as? ClippedPaneHost, !pane.visibleRect.isEmpty {
                let rect = pane.convert(pane.bounds, to: self)
                var ancestor = pane.superview
                while let parent = ancestor, !(parent is MountedTabHost) { ancestor = parent.superview }
                guard let canvas = ancestor else { return }
                let viewport = canvas.convert(canvas.visibleRect, to: self)
                let shape = CGPath(roundedRect: rect, cornerWidth: 12, cornerHeight: 12, transform: nil)
                shapes.append((shape, viewport.insetBy(dx: -48, dy: -48)))
                return
            }
            for child in view.subviews { collect(child) }
        }
        collect(root)
        for (shape, viewport) in shapes {
            context.saveGState()
            context.clip(to: viewport)
            context.setShadow(offset: CGSize(width: 0, height: 2), blur: 15,
                color: NSColor.black.withAlphaComponent(0.15).cgColor)
            context.setFillColor(NSColor.black.cgColor)
            context.addPath(shape)
            context.fillPath()
            context.restoreGState()
        }
        // Remove the silhouettes after drawing every shadow. Translucent panes
        // keep their appearance and no neighboring pane receives a shadow.
        context.setBlendMode(.clear)
        for (shape, _) in shapes {
            context.addPath(shape)
            context.fillPath()
        }
    }
}
