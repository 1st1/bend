import AppKit
import SwiftUI
import BrowseCore

struct PaneDragHandle: NSViewRepresentable {
    let store: BrowserStore
    let tabID: UUID
    let pageID: UUID
    let title: String

    func makeNSView(context: Context) -> PaneDragSourceView { PaneDragSourceView() }
    func updateNSView(_ view: PaneDragSourceView, context: Context) {
        view.store = store; view.tabID = tabID; view.pageID = pageID; view.title = title
    }
}

@MainActor
final class PaneDragSourceView: NSView {
    weak var store: BrowserStore?
    var tabID: UUID?
    var pageID: UUID?
    var title = ""
    private(set) var mouseDownPoint: NSPoint?
    private(set) var dragSurface: PaneDragSurface?
    private var escapeMonitor: Any?
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        cancelDrag()
        guard let store, let tabID, let pageID, store.selectedTab.id == tabID else { return }
        store.focus(pageID)
        mouseDownPoint = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = mouseDownPoint, let store, let tabID,
              store.selectedTab.id == tabID, store.zoomedPane == nil,
              store.selectedTab.pages.count > 1, let window, let content = window.contentView else {
            cancelDrag(); return
        }
        guard dragSurface != nil || hypot(event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y) >= 5 else { return }
        if dragSurface == nil {
            let surface = PaneDragSurface(source: self, content: content, badge: dragBadge())
            dragSurface = surface
            content.addSubview(surface, positioned: .above, relativeTo: nil)
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53, self?.dragSurface != nil else { return event }
                self?.cancelDrag()
                return nil
            }
            NotificationCenter.default.addObserver(self, selector: #selector(windowResigned),
                name: NSWindow.didResignKeyNotification, object: window)
        }
        dragSurface?.update(at: event.locationInWindow)
    }

    override func mouseUp(with event: NSEvent) {
        dragSurface?.update(at: event.locationInWindow)
        let target = dragSurface?.target
        let edge = target?.dropEdge
        let sourceID = target?.validSource(self)
        cancelDrag()
        if let target, let edge, let sourceID, let store, let tabID, let targetID = target.pageID {
            store.movePane(sourceID, beside: targetID, edge: edge, in: tabID)
        }
    }

    override func cancelOperation(_ sender: Any?) { cancelDrag() }
    @objc private func windowResigned(_ notification: Notification) { cancelDrag() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { cancelDrag() }
    }

    func cancelDrag() {
        mouseDownPoint = nil
        dragSurface?.target?.showPreview(nil)
        dragSurface?.removeFromSuperview()
        dragSurface = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor); self.escapeMonitor = nil }
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
    }

    private func dragBadge() -> NSImage {
        let text = NSString(string: title)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
        let size = NSSize(width: min(260, max(100, text.size(withAttributes: attributes).width + 24)), height: 30)
        let image = NSImage(size: size)
        image.lockFocus()
        let rect = NSRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
        NSColor(calibratedWhite: 0.15, alpha: 0.96).setFill()
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        path.fill()
        NSColor.white.withAlphaComponent(0.2).setStroke(); path.stroke()
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        text.draw(in: NSRect(x: 12, y: 7, width: size.width - 24, height: 16),
                  withAttributes: attributes.merging([.paragraphStyle: paragraph]) { _, new in new })
        image.unlockFocus()
        return image
    }
}

// Native pane geometry is used directly during an internal drag; WebKit's
// pasteboard destination and hit testing do not participate.
@MainActor
class PaneDropHost: NSView {
    weak var store: BrowserStore?
    var tabID: UUID?
    var pageID: UUID?
    private(set) var dropEdge: PaneDropEdge?
    private let preview = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        preview.fillColor = NSColor.systemBlue.withAlphaComponent(0.22).cgColor
        preview.strokeColor = NSColor.systemBlue.withAlphaComponent(0.9).cgColor
        preview.lineWidth = 2
        preview.zPosition = 1000
        preview.isHidden = true
        layer?.addSublayer(preview)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func validSource(_ source: PaneDragSourceView) -> UUID? {
        guard let store, source.store === store, let tabID, source.tabID == tabID,
              store.selectedTab.id == tabID, store.zoomedPane == nil,
              let sourceID = source.pageID, let pageID, sourceID != pageID,
              store.selectedTab.pages.contains(where: { $0.id == sourceID }),
              store.selectedTab.pages.contains(where: { $0.id == pageID }),
              !isHiddenOrHasHiddenAncestor else { return nil }
        return sourceID
    }

    func showPreview(_ edge: PaneDropEdge?) {
        dropEdge = edge
        CATransaction.begin(); CATransaction.setDisableActions(true)
        preview.isHidden = edge == nil
        if let edge {
            var rect = edge.preview(in: bounds.size)
            if !isFlipped { rect.origin.y = bounds.height - rect.maxY }
            rect.origin.x += bounds.minX; rect.origin.y += bounds.minY
            preview.path = CGPath(roundedRect: rect.insetBy(dx: 3, dy: 3), cornerWidth: 9, cornerHeight: 9, transform: nil)
        }
        CATransaction.commit()
    }

    override func layout() { super.layout(); showPreview(dropEdge) }
}

// This surface exists only for the duration of a header drag. NSWindow keeps
// sending dragged/up events to the original mouse-down view; forwarding here
// also handles any event delivered to the overlay itself.
@MainActor
final class PaneDragSurface: NSView {
    private weak var source: PaneDragSourceView?
    private let targets: [PaneDropHost]
    private let badge: NSImageView
    private(set) var target: PaneDropHost?
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init(source: PaneDragSourceView, content: NSView, badge image: NSImage) {
        self.source = source
        func panes(in view: NSView) -> [PaneDropHost] {
            if let pane = view as? PaneDropHost { return [pane] }
            return view.subviews.flatMap { panes(in: $0) }
        }
        targets = panes(in: content)
        badge = NSImageView(frame: NSRect(origin: .zero, size: image.size))
        badge.image = image
        super.init(frame: content.bounds)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        addSubview(badge)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(at windowPoint: NSPoint) {
        target?.showPreview(nil)
        target = nil
        guard let source, source.window === window else { return }
        let point = convert(windowPoint, from: nil)
        badge.setFrameOrigin(NSPoint(x: point.x + 12, y: point.y + 12))
        guard bounds.contains(point) else { return }
        for candidate in targets where candidate.window === window && candidate.validSource(source) != nil {
            let local = candidate.convert(windowPoint, from: nil)
            guard candidate.visibleRect.contains(local) else { continue }
            let position = CGPoint(x: local.x - candidate.bounds.minX,
                y: candidate.isFlipped ? local.y - candidate.bounds.minY : candidate.bounds.maxY - local.y)
            guard let edge = PaneDropEdge.at(position, in: candidate.bounds.size) else { continue }
            candidate.showPreview(edge)
            target = candidate
            break
        }
    }

    override func mouseDown(with event: NSEvent) { source?.cancelDrag() }
    override func mouseDragged(with event: NSEvent) { source?.mouseDragged(with: event) }
    override func mouseUp(with event: NSEvent) { source?.mouseUp(with: event) }
    override func cancelOperation(_ sender: Any?) { source?.cancelDrag() }
}
