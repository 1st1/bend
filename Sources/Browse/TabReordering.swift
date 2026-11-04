import AppKit
import SwiftUI

// @lat: [[architecture#Sidebar tab reordering]]
struct TabDragHandle: NSViewRepresentable {
    let store: BrowserStore
    let tabID: UUID
    let title: String
    let reduceMotion: Bool

    func makeNSView(context: Context) -> TabDragSourceView { TabDragSourceView() }
    static func dismantleNSView(_ view: TabDragSourceView, coordinator: ()) { view.cancelDrag() }
    func updateNSView(_ view: TabDragSourceView, context: Context) {
        view.store = store; view.tabID = tabID; view.title = title; view.reduceMotion = reduceMotion
    }
}

@MainActor
final class TabDragSourceView: NSView {
    weak var store: BrowserStore?
    var tabID: UUID?
    var title = ""
    var reduceMotion = false
    private(set) var mouseDownPoint: NSPoint?
    private(set) var dragSurface: TabDragSurface?
    private var monitor: Any?
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        cancelDrag()
        mouseDownPoint = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = mouseDownPoint, let store, let tabID,
              store.session.workspaces.flatMap(\.tabs).contains(where: { $0.id == tabID }),
              let window, let content = window.contentView else { cancelDrag(); return }
        guard dragSurface != nil || hypot(event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y) >= 5 else { return }
        if dragSurface == nil {
            let surface = TabDragSurface(source: self, content: content)
            dragSurface = surface
            content.addSubview(surface, positioned: .above, relativeTo: nil)
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
                guard let self, self.dragSurface != nil else { return event }
                if event.type == .keyDown, event.keyCode == 53 { self.cancelDrag(); return nil }
                guard event.window === self.window else { return event }
                if event.type == .leftMouseDown { self.cancelDrag(); return event }
                if event.type == .leftMouseDragged { self.mouseDragged(with: event); return nil }
                if event.type == .leftMouseUp { self.mouseUp(with: event) }
                // Balance AppKit's press/release tracking even after completing a drop.
                return event
            }
            NotificationCenter.default.addObserver(self, selector: #selector(windowResigned),
                name: NSWindow.didResignKeyNotification, object: window)
        }
        autoscroll(with: event)
        dragSurface?.update(at: event.locationInWindow)
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseDownPoint != nil else { return }
        dragSurface?.update(at: event.locationInWindow)
        let wasDragging = dragSurface != nil
        let placement = dragSurface?.placement
        cancelDrag()
        guard let store, let tabID,
              store.session.workspaces.flatMap(\.tabs).contains(where: { $0.id == tabID }) else { return }
        if let placement {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                _ = store.reorderTab(tabID, relativeTo: placement.tabID, after: placement.after)
            }
        } else if !wasDragging, bounds.contains(convert(event.locationInWindow, from: nil)) {
            store.select(tabID)
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
        dragSurface?.removeFromSuperview(); dragSurface = nil
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
    }
}

@MainActor
final class TabDragSurface: NSView {
    struct Placement: Equatable {
        let tabID: UUID
        let after: Bool
    }
    private weak var source: TabDragSourceView?
    private let marker = CAShapeLayer()
    private let badge = NSTextField(labelWithString: "")
    private(set) var placement: Placement?
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init(source: TabDragSourceView, content: NSView) {
        self.source = source
        super.init(frame: content.bounds)
        autoresizingMask = [.width, .height]; wantsLayer = true
        marker.fillColor = NSColor.systemBlue.cgColor
        marker.isHidden = true
        layer?.addSublayer(marker)
        badge.stringValue = source.title
        badge.font = .systemFont(ofSize: 12, weight: .medium)
        badge.textColor = .white
        badge.lineBreakMode = .byTruncatingTail
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor(calibratedWhite: 0.18, alpha: 0.96).cgColor
        badge.layer?.cornerRadius = 12
        badge.frame.size = NSSize(width: min(240, max(100, badge.intrinsicContentSize.width + 24)), height: 26)
        addSubview(badge)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(at windowPoint: NSPoint) {
        guard let source, let store = source.store, source.window === window, let content = superview else { clearPlacement(); return }
        let point = convert(windowPoint, from: nil)
        badge.setFrameOrigin(NSPoint(x: point.x + 12, y: point.y + 12))
        let targets = descendants(in: content).filter { $0.store === store && !$0.isHiddenOrHasHiddenAncestor }
        guard targets.contains(where: {
            if case .workspace = $0.destination {
                return $0.bounds.intersection($0.visibleRect).contains($0.convert(windowPoint, from: nil))
            }
            return false
        }) else { clearPlacement(); return }
        let rows: [(UUID, NSRect)] = targets.compactMap { view in
            guard case .tab(let id) = view.destination,
                  !view.bounds.intersection(view.visibleRect).isEmpty else { return nil }
            return (id, convert(view.bounds, from: view))
        }.sorted { $0.1.midY < $1.1.midY }
        guard let last = rows.last else { clearPlacement(); return }
        let before = rows.first { point.y < $0.1.midY }
        let row = before ?? last
        guard row.0 != source.tabID else { clearPlacement(); return }
        placement = Placement(tabID: row.0, after: before == nil)
        let y = before == nil ? row.1.maxY + 3.5 : row.1.minY - 3.5
        CATransaction.begin(); CATransaction.setDisableActions(true)
        marker.path = CGPath(roundedRect: NSRect(x: row.1.minX, y: y - 1, width: row.1.width, height: 2),
                             cornerWidth: 1, cornerHeight: 1, transform: nil)
        marker.isHidden = false
        CATransaction.commit()
    }

    private func descendants(in view: NSView) -> [PaneSidebarTargetView] {
        if view === self { return [] }
        return (view as? PaneSidebarTargetView).map { [$0] } ?? view.subviews.flatMap { descendants(in: $0) }
    }
    private func clearPlacement() {
        placement = nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        marker.isHidden = true
        CATransaction.commit()
    }
    override func mouseDown(with event: NSEvent) { source?.cancelDrag() }
    override func mouseDragged(with event: NSEvent) { source?.mouseDragged(with: event) }
    override func mouseUp(with event: NSEvent) { source?.mouseUp(with: event) }
    override func cancelOperation(_ sender: Any?) { source?.cancelDrag() }
}
