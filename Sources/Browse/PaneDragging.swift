import AppKit
import SwiftUI
import BrowseCore

struct PaneDragHandle: NSViewRepresentable {
    let store: BrowserStore
    let tabID: UUID
    let pageID: UUID
    let title: String
    var onHover: ((Bool) -> Void)? = nil

    func makeNSView(context: Context) -> PaneDragSourceView { PaneDragSourceView() }
    static func dismantleNSView(_ view: PaneDragSourceView, coordinator: ()) {
        // SwiftUI may retire this handle while AppKit still keeps it mounted.
        view.onHover = nil
        view.cancelDrag()
    }
    func updateNSView(_ view: PaneDragSourceView, context: Context) {
        view.store = store; view.tabID = tabID; view.pageID = pageID; view.title = title
        view.onHover = onHover
    }
}

@MainActor
final class PaneDragSourceView: NSView {
    weak var store: BrowserStore?
    var tabID: UUID?
    var pageID: UUID?
    var title = ""
    var onHover: ((Bool) -> Void)?
    private var hoverTracking: NSTrackingArea?
    private(set) var isHovering = false
    private(set) var mouseDownPoint: NSPoint?
    private(set) var dragSurface: PaneDragSurface?
    weak var trackingWindow: BrowseWindow?
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
        hoverTracking = tracking
    }

    private func setHovering(_ hovering: Bool) {
        guard isHovering != hovering else { return }
        isHovering = hovering
        onHover?(hovering)
    }

    override func mouseEntered(with event: NSEvent) { setHovering(true) }
    override func mouseExited(with event: NSEvent) { setHovering(false) }

    override func mouseDown(with event: NSEvent) {
        cancelDrag()
        guard let store, let tabID, let pageID, store.selectedTab.id == tabID else { return }
        store.focus(pageID)
        mouseDownPoint = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = mouseDownPoint, let store, let tabID,
              store.session.workspaces.flatMap(\.tabs).contains(where: { $0.id == tabID && $0.pages.contains { $0.id == pageID } }),
              (dragSurface != nil || store.selectedTab.id == tabID), store.zoomedPane == nil,
              let window, let content = window.contentView else {
            cancelDrag(); return
        }
        guard dragSurface != nil || hypot(event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y) >= 5 else { return }
        if dragSurface == nil {
            let surface = PaneDragSurface(source: self, content: content, badge: dragBadge())
            dragSurface = surface
            content.addSubview(surface, positioned: .above, relativeTo: nil)

        }
        dragSurface?.update(at: event.locationInWindow)
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseDownPoint != nil else { return }
        dragSurface?.update(at: event.locationInWindow)
        let target = dragSurface?.target
        let sidebarTarget = dragSurface?.sidebarTarget
        let edge = target?.dropEdge
        let sourceID = target?.validSource(self)
        cancelDrag()
        if let target, let edge, let sourceID, let store, let tabID, let targetID = target.pageID {
            if let destination = target.tabID {
                store.movePane(sourceID, beside: targetID, edge: edge, in: destination, from: tabID)
            }
        } else if let sidebarTarget, let store, let tabID, let pageID {
            switch sidebarTarget.destination {
            case .tab(let destination) where destination != tabID:
                guard let tab = store.session.workspaces.flatMap(\.tabs).first(where: { $0.id == destination }) else { return }
                store.select(destination)
                store.movePane(pageID, beside: tab.focusedPane, edge: .right, in: destination, from: tabID)
            case .workspace(let workspace):
                store.detachPane(pageID, from: tabID, into: workspace)
            default: break
            }
        }
    }

    override func cancelOperation(_ sender: Any?) { cancelDrag() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { cancelDrag(); setHovering(false) }
    }

    func cancelDrag() {
        mouseDownPoint = nil
        dragSurface?.clearTargets()
        dragSurface?.removeFromSuperview()
        dragSurface = nil
        trackingWindow?.releasePaneDrag(self)
        trackingWindow = nil
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
    private var previewBounds: NSRect = .zero

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
        guard let store, source.store === store, let tabID, let sourceTabID = source.tabID,
              store.selectedTab.id == tabID, store.zoomedPane == nil,
              let sourceID = source.pageID, let pageID, sourceID != pageID,
              store.session.workspaces.flatMap(\.tabs).contains(where: { $0.id == sourceTabID && $0.pages.contains { $0.id == sourceID } }),
              store.selectedTab.pages.contains(where: { $0.id == pageID }),
              !isHiddenOrHasHiddenAncestor else { return nil }
        return sourceID
    }

    func showPreview(_ edge: PaneDropEdge?) {
        guard edge != dropEdge || (edge != nil && previewBounds != bounds) else { return }
        dropEdge = edge
        previewBounds = bounds
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

// The surface is purely visual: BrowseWindow owns the entire mouse gesture.
// It must never shield the window if SwiftUI retires or replaces a drag handle.
@MainActor
final class PaneDragSurface: NSView {
    private weak var source: PaneDragSourceView?
    private let badge: NSImageView
    private(set) var target: PaneDropHost?
    private(set) var sidebarTarget: PaneSidebarTargetView?
    private var hoverTask: Task<Void, Never>?
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init(source: PaneDragSourceView, content: NSView, badge image: NSImage) {
        self.source = source
        badge = NSImageView(frame: NSRect(origin: .zero, size: image.size))
        badge.image = image
        super.init(frame: content.bounds)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        addSubview(badge)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(at windowPoint: NSPoint) {
        guard let source, source.window === window else { clearTargets(); return }
        let point = convert(windowPoint, from: nil)
        badge.setFrameOrigin(NSPoint(x: point.x + 12, y: point.y + 12))
        guard bounds.contains(point), let content = superview else { clearTargets(); return }
        let sidebar = descendants(of: PaneSidebarTargetView.self, in: content).filter {
            $0.store === source.store && !$0.isHiddenOrHasHiddenAncestor
                && $0.bounds.intersection($0.visibleRect).contains($0.convert(windowPoint, from: nil))
        }
        // Rows take precedence over the containing workspace's empty-space target.
        let hovered = sidebar.first { if case .tab = $0.destination { return true }; return false }
            ?? sidebar.min { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
        if sidebarTarget !== hovered {
            sidebarTarget?.showPreview(false)
            hoverTask?.cancel(); hoverTask = nil
            sidebarTarget = hovered
            if let hovered, case .tab(let id) = hovered.destination, let store = source.store,
               store.session.selectedTab != id {
                hoverTask = Task { @MainActor [weak self, weak store] in
                    do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
                    guard let self, self.sidebarTarget === hovered, let store,
                          store.session.workspaces.flatMap(\.tabs).contains(where: { $0.id == id }) else { return }
                    store.select(id)
                }
            }
        }
        if let hovered {
            setTarget(nil)
            hovered.showPreview(true, at: hovered.convert(windowPoint, from: nil))
            return
        }
        // Tab hovering can mount a previously unvisited canvas while dragging.
        let targets = descendants(of: PaneDropHost.self, in: content)
        for candidate in targets where candidate.window === window && candidate.validSource(source) != nil {
            let local = candidate.convert(windowPoint, from: nil)
            guard candidate.bounds.intersection(candidate.visibleRect).contains(local) else { continue }
            let position = CGPoint(x: local.x - candidate.bounds.minX,
                y: candidate.isFlipped ? local.y - candidate.bounds.minY : candidate.bounds.maxY - local.y)
            guard let edge = PaneDropEdge.at(position, in: candidate.bounds.size) else { continue }
            setTarget(candidate, edge: edge)
            return
        }
        setTarget(nil)
    }

    private func setTarget(_ next: PaneDropHost?, edge: PaneDropEdge? = nil) {
        // Keep an unchanged target visible across pointer events. Clearing it
        // first lets an intermediate hidden layer reach the compositor.
        if target !== next { target?.showPreview(nil); target = next }
        next?.showPreview(edge)
    }

    private func descendants<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        if view === self { return [] }
        return (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(of: type, in: $0) }
    }

    func clearTargets() {
        hoverTask?.cancel(); hoverTask = nil
        setTarget(nil)
        sidebarTarget?.showPreview(false); sidebarTarget = nil
    }

    override func mouseDown(with event: NSEvent) { source?.cancelDrag() }
    override func mouseDragged(with event: NSEvent) { source?.mouseDragged(with: event) }
    override func mouseUp(with event: NSEvent) { source?.mouseUp(with: event) }
    override func cancelOperation(_ sender: Any?) { source?.cancelDrag() }
}

enum PaneSidebarDestination: Equatable {
    case tab(UUID)
    case workspace(UUID)
}

struct PaneSidebarTarget: NSViewRepresentable {
    let store: BrowserStore
    let destination: PaneSidebarDestination
    func makeNSView(context: Context) -> PaneSidebarTargetView { PaneSidebarTargetView() }
    func updateNSView(_ view: PaneSidebarTargetView, context: Context) {
        view.store = store; view.destination = destination
    }
}

@MainActor final class PaneSidebarTargetView: NSView {
    weak var store: BrowserStore?
    var destination: PaneSidebarDestination = .workspace(UUID())
    private let preview = CAShapeLayer()
    private var previewRect: NSRect = .zero
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        preview.fillColor = NSColor.systemBlue.withAlphaComponent(0.22).cgColor
        preview.strokeColor = NSColor.systemBlue.withAlphaComponent(0.9).cgColor
        preview.lineWidth = 1
        preview.isHidden = true
        layer?.addSublayer(preview)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func showPreview(_ visible: Bool, at point: NSPoint = .zero) {
        let rect: NSRect
        switch destination {
        case .tab: rect = bounds.insetBy(dx: 1, dy: 1)
        case .workspace: rect = NSRect(x: 10, y: point.y, width: max(0, bounds.width - 20), height: 2)
        }
        if !visible, preview.isHidden { return }
        if visible, !preview.isHidden, rect == previewRect { return }
        previewRect = rect
        CATransaction.begin(); CATransaction.setDisableActions(true)
        preview.isHidden = !visible
        switch destination {
        case .tab:
            preview.path = CGPath(roundedRect: rect, cornerWidth: 12, cornerHeight: 12, transform: nil)
        case .workspace:
            preview.path = CGPath(rect: rect, transform: nil)
        }
        CATransaction.commit()
    }
}
