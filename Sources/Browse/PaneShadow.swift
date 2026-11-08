import AppKit
import SwiftUI

// Shadows and outlines belong to the window background, outside clipped pane
// canvases. They follow pane geometry without consuming any layout space.
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
        var shapes: [(path: CGPath, viewport: CGRect, color: CGColor, blur: CGFloat,
                      offset: CGSize, outline: (path: CGPath, color: CGColor)?)] = []
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
                var offset = CGSize(width: 0, height: 2)
                var outline: (path: CGPath, color: CGColor)?
                var outlineReach: CGFloat = 0
                if let store = pane.store, pane.tabID == store.selectedTab.id,
                   pane.pageID == store.selectedTab.focusedPane {
                    let appearance = store.paneHighlight
                    if appearance.style == .glow {
                        color = appearance.glowColor.nsColor.withAlphaComponent(appearance.glowIntensity)
                        blur = appearance.glowSpread
                        // A focus halo must be centered; the ordinary drop
                        // shadow's vertical offset makes its falloff uneven.
                        offset = .zero
                    } else if appearance.style == .outline {
                        let gap = CGFloat(appearance.outlineGap)
                        outlineReach = gap + CGFloat(appearance.outlineWidth)
                        let ring = CGMutablePath()
                        ring.addRoundedRect(in: rect.insetBy(dx: -outlineReach, dy: -outlineReach),
                                            cornerWidth: 12 + outlineReach, cornerHeight: 12 + outlineReach)
                        ring.addRoundedRect(in: rect.insetBy(dx: -gap, dy: -gap),
                                            cornerWidth: 12 + gap, cornerHeight: 12 + gap)
                        outline = (ring, appearance.outlineColor.nsColor.cgColor)
                    }
                }
                let reach = max(48, blur * 3 + 3, outlineReach)
                shapes.append((shape, viewport.insetBy(dx: -reach, dy: -reach), color.cgColor, blur, offset, outline))
                return
            }
            for child in view.subviews { collect(child) }
        }
        collect(root)
        for shadow in shapes {
            context.saveGState()
            context.clip(to: shadow.viewport)
            context.setShadow(offset: shadow.offset, blur: shadow.blur, color: shadow.color)
            context.setFillColor(NSColor.black.cgColor)
            context.addPath(shadow.path)
            context.fillPath()
            context.restoreGState()
        }
        for decoration in shapes {
            guard let outline = decoration.outline else { continue }
            context.saveGState()
            context.clip(to: decoration.viewport)
            context.setFillColor(outline.color)
            context.addPath(outline.path)
            context.drawPath(using: .eoFill)
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
