import AppKit
import WebKit
import BrowseCore

// A nonactivating, mouse-transparent card can follow a captured gesture beyond
// the source window without becoming a drop target or taking keyboard focus.
@MainActor
final class DetachedDragPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class DetachedDragPreview {
    let panel: DetachedDragPanel
    private let canvas: DragPreviewCanvas
    private(set) var expanded = false
    private let reduceMotion: Bool
    private var pointer = NSPoint.zero
    private var size = NSSize(width: 240, height: 144)
    private var transition: (from: NSSize, to: NSSize, start: TimeInterval)?
    private var resizeTimer: Timer?

    init(store: BrowserStore, tab: BrowserTab, pane: UUID?, title: String, source: NSWindow) {
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        func panes(in view: NSView) -> [PaneDropHost] {
            if let pane = view as? PaneDropHost { return [pane] }
            return view.subviews.flatMap { panes(in: $0) }
        }
        let pages = pane.map { id in tab.pages.filter { $0.id == id } } ?? tab.pages
        let mounted = (source.contentView.map { panes(in: $0) } ?? [])
            .filter { host in pages.contains { $0.id == host.pageID } }
        let mountedBounds = mounted.reduce(NSRect.null) { bounds, host in
            bounds.union(host.convert(host.bounds, to: nil))
        }
        let viewport = !mountedBounds.isNull && !mountedBounds.isEmpty ? mountedBounds.size
            : NSSize(width: max(780, source.frame.width - store.sidebarWidth), height: max(500, source.frame.height - 40))
        let layout = pane.map(PaneLayout.pane) ?? tab.layout
        let frames = Dictionary(mounted.compactMap { host -> (UUID, NSRect)? in
            guard let id = host.pageID else { return nil }
            let rect = host.convert(host.bounds, to: nil)
            return (id, NSRect(x: rect.minX - mountedBounds.minX, y: mountedBounds.maxY - rect.maxY,
                               width: rect.width, height: rect.height))
        }, uniquingKeysWith: { first, _ in first })
        canvas = DragPreviewCanvas(layout: layout, pages: pages, viewport: viewport, frames: frames)
        panel = DetachedDragPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = true; panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces, .ignoresCycle]
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.alphaValue = 0.93
        let card = NSVisualEffectView()
        card.material = .popover; card.blendingMode = .behindWindow; card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 10; card.layer?.masksToBounds = true
        card.layer?.borderWidth = 0.5; card.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        panel.contentView = card
        let shade = NSView()
        shade.wantsLayer = true
        shade.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor
        shade.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(shade)
        NSLayoutConstraint.activate([
            shade.leadingAnchor.constraint(equalTo: card.leadingAnchor), shade.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            shade.topAnchor.constraint(equalTo: card.topAnchor), shade.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor; label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.init(rawValue: 1), for: .horizontal)
        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.image = pages.first.flatMap { store.existingController(for: $0.id)?.favicon }
            ?? NSImage(systemSymbolName: pane == nil && pages.count > 1 ? "rectangle.split.2x1" : "globe", accessibilityDescription: nil)
        for view in [icon, label, canvas] {
            view.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 9),
            icon.topAnchor.constraint(equalTo: card.topAnchor, constant: 7),
            icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -9),
            label.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            canvas.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 4),
            canvas.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -4),
            canvas.topAnchor.constraint(equalTo: card.topAnchor, constant: 30),
            canvas.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -4)
        ])
        for page in pages {
            // Never bitmap-render the live pane: its native glass backdrop is
            // window-composited. Draw miniature chrome separately and ask only
            // WebKit for page pixels, leaving the live header tree untouched.
            canvas.titles[page.id] = store.existingController(for: page.id)?.title
            if let controller = store.existingController(for: page.id), !controller.isStartPage,
               let host = mounted.first(where: { $0.pageID == page.id }),
               controller.webView.isDescendant(of: host), !controller.webView.bounds.isEmpty {
                let captureRect = (controller.webView.superview as? WebSurfaceHost)?.snapshotContentRect
                    ?? controller.webView.bounds
                guard !captureRect.isEmpty else { continue }
                let webRect = host.convert(captureRect, from: controller.webView)
                let body = NSRect(x: webRect.minX - host.bounds.minX,
                    y: host.isFlipped ? webRect.minY - host.bounds.minY : host.bounds.maxY - webRect.maxY,
                    width: webRect.width, height: webRect.height)
                canvas.headerHeights[page.id] = body.minY
                let configuration = WKSnapshotConfiguration()
                configuration.rect = captureRect
                configuration.snapshotWidth = 640
                controller.webView.takeSnapshot(with: configuration) { [weak self] image, _ in
                    guard let self, let image else { return }
                    self.canvas.updateWebSnapshot(image, for: page.id, in: body)
                }
            }
        }
    }

    func update(at point: NSPoint, expanded: Bool) {
        pointer = point
        let now = ProcessInfo.processInfo.systemUptime
        advanceSize(at: now)
        let limit: CGFloat = expanded ? 250 : 240
        let aspectRatio = canvas.contentSize.width / canvas.contentSize.height
        let width = min(limit, (limit - 34) * aspectRatio + 8)
        // Fit the card to its thumbnail, including only the title bar and border.
        // Both endpoints share this ratio, so interpolation preserves it too.
        let target = NSSize(width: width, height: (width - 8) / aspectRatio + 34)
        if !panel.isVisible || reduceMotion {
            size = target
            stopResizing()
        } else if self.expanded != expanded {
            transition = (size, target, now)
            if resizeTimer == nil {
                let timer = Timer(timeInterval: 1 / 120, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.resizeFrame() }
                }
                resizeTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
        }
        self.expanded = expanded
        placeAtPointer()
        if !panel.isVisible { panel.orderFront(nil) }
    }

    private func advanceSize(at time: TimeInterval) {
        guard let transition else { return }
        let t = min(1, max(0, (time - transition.start) / 0.14))
        let eased = t * t * (3 - 2 * t)
        size = NSSize(width: transition.from.width + (transition.to.width - transition.from.width) * eased,
                      height: transition.from.height + (transition.to.height - transition.from.height) * eased)
        if t == 1 { stopResizing() }
    }

    private func resizeFrame() {
        advanceSize(at: ProcessInfo.processInfo.systemUptime)
        placeAtPointer()
    }

    private func placeAtPointer() {
        // Position always follows the latest event, including during resizing.
        // An NSWindow animator would replay an older origin between mouse events.
        let origin = NSPoint(x: pointer.x - size.width * 0.46, y: pointer.y - size.height * 0.5)
        if panel.frame.size == size {
            if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        } else {
            panel.setFrame(NSRect(origin: origin, size: size), display: false)
        }
    }

    private func stopResizing() {
        transition = nil
        resizeTimer?.invalidate(); resizeTimer = nil
    }

    func hide() { stopResizing(); panel.orderOut(nil) }
    func close() { stopResizing(); panel.close() }

}

@MainActor
final class DragPreviewCanvas: NSView {
    let contentSize: NSSize
    let paneFrames: [UUID: NSRect]
    let pages: [Page]
    var images: [UUID: NSImage] = [:]
    var titles: [UUID: String] = [:]
    var headerHeights: [UUID: CGFloat] = [:]
    override var isFlipped: Bool { true }
    init(layout: PaneLayout, pages: [Page], viewport: NSSize, frames: [UUID: NSRect] = [:]) {
        self.pages = pages
        if pages.allSatisfy({ frames[$0.id]?.isEmpty == false }) {
            contentSize = viewport
            paneFrames = frames
        } else {
            let geometry = PaneGeometry(layout: layout, viewport: viewport)
            contentSize = geometry.size
            paneFrames = Dictionary(uniqueKeysWithValues: geometry.panes.map { ($0.id, $0.frame) })
        }
        super.init(frame: .zero)
        wantsLayer = true; layer?.cornerRadius = 5; layer?.masksToBounds = true
        layerContentsRedrawPolicy = .duringViewResize
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }
    func updateWebSnapshot(_ image: NSImage, for id: UUID, in body: NSRect) {
        guard let frame = paneFrames[id], !body.isEmpty else { return }
        let background = images[id]
        images[id] = NSImage(size: frame.size, flipped: true) { rect in
            background?.draw(in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
            image.draw(in: body, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
            return true
        }
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let scale = min(bounds.width / contentSize.width, bounds.height / contentSize.height)
        for page in pages {
            guard let frame = paneFrames[page.id] else { continue }
            let rect = NSRect(x: frame.minX * scale, y: frame.minY * scale,
                              width: frame.width * scale, height: frame.height * scale)
            NSColor(calibratedWhite: 0.08, alpha: 0.86).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
            let header = NSRect(x: rect.minX, y: rect.minY, width: rect.width,
                                height: min((headerHeights[page.id] ?? Chrome.paneHeaderHeight) * scale, rect.height))
            NSColor.white.withAlphaComponent(0.045).setFill(); header.fill()
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
            NSString(string: titles[page.id] ?? page.address).draw(
                in: header.insetBy(dx: 12 * scale, dy: 10 * scale),
                withAttributes: [.font: NSFont.systemFont(ofSize: 12 * scale),
                    .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph])
            if let image = images[page.id] {
                image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.92, respectFlipped: true, hints: nil)
            }
        }
    }
}
