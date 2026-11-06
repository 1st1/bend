import AppKit
import SwiftUI

// Shadows belong to the window background, outside the clipped pane canvases.
struct PaneShadowPlane: NSViewRepresentable {
    @ObservedObject var store: BrowserStore
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
        var shapes: [(path: CGPath, viewport: CGRect, color: CGColor, blur: CGFloat)] = []
        func collect(_ view: NSView) {
            guard !view.isHiddenOrHasHiddenAncestor else { return }
            if let pane = view as? ClippedPaneHost, !pane.visibleRect.isEmpty {
                let rect = pane.convert(pane.bounds, to: self)
                var ancestor = pane.superview
                while let parent = ancestor, !(parent is MountedTabHost) { ancestor = parent.superview }
                guard let canvas = ancestor else { return }
                let viewport = canvas.convert(canvas.visibleRect, to: self)
                let shape = CGPath(roundedRect: rect, cornerWidth: 12, cornerHeight: 12, transform: nil)
                var color = NSColor.black.withAlphaComponent(0.15)
                var blur: CGFloat = 15
                if let store = pane.store, pane.tabID == store.selectedTab.id,
                   pane.pageID == store.selectedTab.focusedPane, store.paneHighlight.style == .glow {
                    let appearance = store.paneHighlight
                    color = appearance.glowColor.nsColor.withAlphaComponent(appearance.glowIntensity)
                    blur = appearance.glowSpread
                }
                let reach = max(48, blur * 3 + 3)
                shapes.append((shape, viewport.insetBy(dx: -reach, dy: -reach), color.cgColor, blur))
                return
            }
            for child in view.subviews { collect(child) }
        }
        collect(root)
        for shadow in shapes {
            context.saveGState()
            context.clip(to: shadow.viewport)
            context.setShadow(offset: CGSize(width: 0, height: 2), blur: shadow.blur, color: shadow.color)
            context.setFillColor(NSColor.black.cgColor)
            context.addPath(shadow.path)
            context.fillPath()
            context.restoreGState()
        }
        // Remove the silhouettes after drawing every shadow. Translucent panes
        // keep their appearance and no neighboring pane receives a shadow.
        context.setBlendMode(.clear)
        for shadow in shapes {
            context.addPath(shadow.path)
            context.fillPath()
        }
    }
}
