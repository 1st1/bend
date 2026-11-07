import AppKit
import SwiftUI
import BrowseCore

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
        InputDiagnostics.record(.tabHandle, event: event, view: self)
        cancelDrag()
        mouseDownPoint = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        InputDiagnostics.record(.tabHandle, event: event, view: self)
        guard let origin = mouseDownPoint, let store, let tabID,
              store.session.workspaces.flatMap(\.tabs).contains(where: { $0.id == tabID }),
              let window, let content = window.contentView else { cancelDrag(); return }
        guard dragSurface != nil || hypot(event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y) >= 5 else { return }
        if dragSurface == nil {
            let surface = TabDragSurface(source: self, content: content)
            dragSurface = surface
            InputDiagnostics.transition(.tabDrag, .started, view: self, tabID: tabID)
            content.addSubview(surface, positioned: .above, relativeTo: nil)
            InputDiagnostics.transition(.tabMonitorLifetime, .created, view: self, tabID: tabID)
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
                InputDiagnostics.record(.tabMonitor, event: event, view: self)
                guard let self, self.dragSurface != nil else { return event }
                if event.type == .keyDown, event.keyCode == 53 { self.cancelDrag(); return nil }
                guard event.window === self.window else { return event }
                if event.type == .leftMouseDown { self.cancelDrag(); return event }
                if event.type == .leftMouseDragged {
                    self.mouseDragged(with: event)
                    InputDiagnostics.record(.tabMonitorConsumed, event: event, view: self)
                    return nil
                }
                if event.type == .leftMouseUp { self.mouseUp(with: event) }
                InputDiagnostics.record(.tabMonitorReturned, event: event, view: self)
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
        InputDiagnostics.record(.tabHandle, event: event, view: self)
        guard mouseDownPoint != nil else { return }
        dragSurface?.update(at: event.locationInWindow)
        let wasDragging = dragSurface != nil
        let placement = dragSurface?.placement
        let destinationWindow = dragSurface?.window
        let destinationStore = dragSurface?.destinationStore
        InputDiagnostics.transition(.tabDrop, .requested, view: self, tabID: tabID, flags: ["hasTarget": placement != nil])
        cancelDrag()
        guard let store, let tabID,
              store.session.workspaces.flatMap(\.tabs).contains(where: { $0.id == tabID }) else { return }
        if let placement {
            if let destinationStore, destinationStore !== store {
                let target: WindowDropPlacement
                switch placement {
                case .reorder(let id, let after): target = .insert(relativeTo: id, after: after)
                case .join(let id): target = .join(tab: id, pane: nil, edge: .right)
                case .joinAtPane(let id, let pane, let edge): target = .join(tab: id, pane: pane, edge: edge)
                }
                if store.transfer(tab: tabID, to: destinationStore, at: target) {
                    destinationWindow?.makeKeyAndOrderFront(nil)
                }
                return
            }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                switch placement {
                case .reorder(let destination, let after):
                    _ = store.reorderTab(tabID, relativeTo: destination, after: after)
                case .join(let destination):
                    _ = store.joinTabs(tabID, into: destination)
                case .joinAtPane(let destination, let pane, let edge):
                    _ = store.joinTabs(tabID, into: destination, beside: pane, edge: edge)
                }
            }
        } else if !wasDragging, bounds.contains(convert(event.locationInWindow, from: nil)) {
            store.select(tabID)
        }
    }

    override func cancelOperation(_ sender: Any?) { cancelDrag() }
    @objc private func windowResigned(_ notification: Notification) { cancelDrag() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        InputDiagnostics.transition(.tabHandleLifetime, window == nil ? .detached : .attached, view: self, tabID: tabID)
        if window == nil { cancelDrag() }
    }
    func cancelDrag() {
        if mouseDownPoint != nil { InputDiagnostics.transition(.tabDrag, .finished, view: self, tabID: tabID) }
        mouseDownPoint = nil
        dragSurface?.clearPlacement()
        dragSurface?.removeFromSuperview(); dragSurface = nil
        if let monitor {
            NSEvent.removeMonitor(monitor); self.monitor = nil
            InputDiagnostics.transition(.tabMonitorLifetime, .removed, view: self, tabID: tabID)
        }
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
    }
}

@MainActor
final class TabDragSurface: NSView {
    enum Placement: Equatable {
        case reorder(tabID: UUID, after: Bool)
        case join(tabID: UUID)
        case joinAtPane(tabID: UUID, paneID: UUID, edge: PaneDropEdge)
    }
    private weak var source: TabDragSourceView?
    private let marker = CAShapeLayer()
    private let badge = NSTextField(labelWithString: "")
    private(set) var placement: Placement? {
        didSet {
            if placement != nil { WindowDragTarget.reveal(window, from: source?.window) }
        }
    }
    private(set) var paneTarget: PaneDropHost?
    private var hoverTabID: UUID?
    private var hoverTask: Task<Void, Never>?
    var destinationStore: BrowserStore? { (window as? BrowseWindow)?.browserStore ?? source?.store }
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
        guard let source, let sourceStore = source.store, let sourceWindow = source.window,
              sourceStore.session.workspaces.flatMap(\.tabs).contains(where: { $0.id == source.tabID }),
              let windowPoint = WindowDragTarget.mount(self, from: sourceWindow, store: sourceStore, at: windowPoint),
              let store = destinationStore, let content = superview else {
            isHidden = true; clearPlacement(); return
        }
        let point = convert(windowPoint, from: nil)
        badge.setFrameOrigin(NSPoint(x: point.x + 12, y: point.y + 12))
        guard bounds.contains(point) else { clearPlacement(); return }
        let targets = descendants(of: PaneSidebarTargetView.self, in: content).filter { $0.store === store && !$0.isHiddenOrHasHiddenAncestor }
        guard targets.contains(where: {
            if case .workspace = $0.destination {
                return $0.bounds.intersection($0.visibleRect).contains($0.convert(windowPoint, from: nil))
            }
            return false
        }) else {
            updateHover(nil)
            updatePaneTarget(at: windowPoint, content: content, store: store, sourceID: source.tabID)
            return
        }
        setPaneTarget(nil)
        let rows: [(UUID, NSRect)] = targets.compactMap { view in
            guard case .tab(let id) = view.destination,
                  !view.bounds.intersection(view.visibleRect).isEmpty else { return nil }
            return (id, convert(view.bounds.intersection(view.visibleRect), from: view))
        }.sorted { $0.1.midY < $1.1.midY }
        guard let last = rows.last else { clearPlacement(); return }
        // The middle of a row joins; narrow top/bottom bands keep reordering
        // available without requiring a modifier key or a hover timer.
        if let row = rows.first(where: { $0.1.insetBy(dx: 0, dy: $0.1.height * 0.2).contains(point) }) {
            guard row.0 != source.tabID else { clearPlacement(); return }
            placement = .join(tabID: row.0)
            updateHover(row.0)
            badge.stringValue = "Join tabs"
            CATransaction.begin(); CATransaction.setDisableActions(true)
            marker.fillColor = NSColor.systemBlue.withAlphaComponent(0.22).cgColor
            marker.strokeColor = NSColor.systemBlue.cgColor
            marker.path = CGPath(roundedRect: row.1.insetBy(dx: 1, dy: 1),
                                 cornerWidth: 12, cornerHeight: 12, transform: nil)
            marker.isHidden = false
            CATransaction.commit()
            return
        }
        let before = rows.first { point.y < $0.1.midY }
        let row = before ?? last
        guard row.0 != source.tabID else { clearPlacement(); return }
        placement = .reorder(tabID: row.0, after: before == nil)
        updateHover(nil)
        badge.stringValue = source.title
        let y = before == nil ? row.1.maxY + 3.5 : row.1.minY - 3.5
        CATransaction.begin(); CATransaction.setDisableActions(true)
        marker.fillColor = NSColor.systemBlue.cgColor
        marker.strokeColor = nil
        marker.path = CGPath(roundedRect: NSRect(x: row.1.minX, y: y - 1, width: row.1.width, height: 2),
                             cornerWidth: 1, cornerHeight: 1, transform: nil)
        marker.isHidden = false
        CATransaction.commit()
    }

    private func updateHover(_ id: UUID?) {
        guard id != hoverTabID else { return }
        hoverTask?.cancel(); hoverTask = nil
        hoverTabID = id
        guard let id, let store = destinationStore, store.session.selectedTab != id else { return }
        hoverTask = Task { @MainActor [weak self, weak store] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard let self, let store, self.hoverTabID == id, self.source?.dragSurface === self,
                  let sourceID = self.source?.tabID,
                  self.source?.store?.session.workspaces.flatMap(\.tabs).contains(where: { $0.id == sourceID }) == true,
                  store.session.workspaces.flatMap(\.tabs).contains(where: { $0.id == id }) else { return }
            InputDiagnostics.transition(.tabHoverSelection, .changed, view: self.source, tabID: id)
            store.select(id)
        }
    }

    private func updatePaneTarget(at point: NSPoint, content: NSView, store: BrowserStore, sourceID: UUID?) {
        guard store.zoomedPane == nil, store.selectedTab.id != sourceID else { clearPlacement(); return }
        for candidate in descendants(of: PaneDropHost.self, in: content) {
            guard candidate.store === store, candidate.window === window, !candidate.isHiddenOrHasHiddenAncestor,
                  candidate.tabID == store.selectedTab.id, let pane = candidate.pageID,
                  store.selectedTab.pages.contains(where: { $0.id == pane }) else { continue }
            let local = candidate.convert(point, from: nil)
            guard candidate.bounds.intersection(candidate.visibleRect).contains(local) else { continue }
            let position = CGPoint(x: local.x - candidate.bounds.minX,
                y: candidate.isFlipped ? local.y - candidate.bounds.minY : candidate.bounds.maxY - local.y)
            guard let edge = PaneDropEdge.at(position, in: candidate.bounds.size) else { continue }
            placement = .joinAtPane(tabID: store.selectedTab.id, paneID: pane, edge: edge)
            badge.stringValue = "Join tabs"
            marker.isHidden = true
            setPaneTarget(candidate, edge: edge)
            return
        }
        clearPlacement()
    }

    private func setPaneTarget(_ target: PaneDropHost?, edge: PaneDropEdge? = nil) {
        if paneTarget !== target {
            InputDiagnostics.transition(.tabDrop, .changed, view: source, tabID: target?.tabID,
                                        relatedPaneID: target?.pageID, flags: ["hasTarget": target != nil])
            paneTarget?.showPreview(nil)
            paneTarget = target
        }
        target?.showPreview(edge)
    }

    private func descendants<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        if view === self { return [] }
        return (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(of: type, in: $0) }
    }
    func clearPlacement() {
        updateHover(nil)
        setPaneTarget(nil)
        placement = nil
        badge.stringValue = source?.title ?? ""
        CATransaction.begin(); CATransaction.setDisableActions(true)
        marker.isHidden = true
        CATransaction.commit()
    }
    override func mouseDown(with event: NSEvent) { source?.cancelDrag() }
    override func mouseDragged(with event: NSEvent) { source?.mouseDragged(with: event) }
    override func mouseUp(with event: NSEvent) { source?.mouseUp(with: event) }
    override func cancelOperation(_ sender: Any?) { source?.cancelDrag() }
}
