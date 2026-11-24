import AppKit
import SwiftUI
import BrowseCore

@MainActor
final class TabReorderPreview: ObservableObject {
    @Published var draggedID: UUID?
    @Published private(set) var offsets: [UUID: Int] = [:]

    func show(tabs: [BrowserTab], source: UUID, target: UUID, after: Bool) {
        var order = tabs.map(\.id)
        order.removeAll { $0 == source }
        guard let index = order.firstIndex(of: target) else { clear(); return }
        order.insert(source, at: index + (after ? 1 : 0))
        let original = Dictionary(uniqueKeysWithValues: tabs.enumerated().map { ($1.id, $0) })
        var next: [UUID: Int] = [:]
        for (index, id) in order.enumerated() {
            if let previous = original[id], index != previous { next[id] = index - previous }
        }
        if offsets != next { offsets = next }
    }

    func clear() {
        if !offsets.isEmpty { offsets = [:] }
    }
}

private struct HiddenTabContent: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var hidesDraggedTabContent: Bool {
        get { self[HiddenTabContent.self] }
        set { self[HiddenTabContent.self] = newValue }
    }
}

struct TabReorderOffset: ViewModifier {
    @ObservedObject var preview: TabReorderPreview
    let id: UUID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let slots = preview.offsets[id, default: 0]
        let dragging = preview.draggedID == id
        content.environment(\.hidesDraggedTabContent, dragging)
            .offset(y: dragging ? 0 : CGFloat(slots) * (Chrome.sidebarTabHeight + Chrome.sidebarTabSpacing))
            .animation(reduceMotion || dragging || preview.offsets.isEmpty ? nil : .easeOut(duration: 0.15), value: slots)
    }
}

// @lat: [[lat.md/architecture/sidebar#Sidebar tab reordering]]
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
    private(set) var dragPreview: DetachedDragPreview?
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
            if store.session.selectedTab != tabID { store.select(tabID) }
            if let tab = store.session.workspaces.flatMap(\.tabs).first(where: { $0.id == tabID }) {
                dragPreview = DetachedDragPreview(store: store, tab: tab, pane: nil, title: title, source: window)
            }
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
        let screenPoint = window.convertPoint(toScreen: event.locationInWindow)
        if window.frame.contains(screenPoint) {
            dragPreview?.hide()
        } else {
            dragPreview?.update(at: screenPoint, expanded: WindowDragTarget.previewExpanded(
                at: screenPoint, store: store, wasExpanded: dragPreview?.expanded == true))
        }
        dragSurface?.update(at: event.locationInWindow)
    }

    override func mouseUp(with event: NSEvent) {
        InputDiagnostics.record(.tabHandle, event: event, view: self)
        guard mouseDownPoint != nil else { return }
        dragSurface?.update(at: event.locationInWindow)
        let outsidePoint = dragSurface == nil ? nil
            : WindowDragTarget.newWindowPoint(from: window, at: event.locationInWindow, store: store)
        let wasDragging = dragSurface != nil
        let returningToSource = dragSurface?.isReturningToSource == true
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
            switch placement {
            case .reorder(let destination, let after):
                _ = store.reorderTab(tabID, relativeTo: destination, after: after)
                if returningToSource { store.select(tabID) }
            case .join(let destination):
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                    _ = store.joinTabs(tabID, into: destination)
                }
            case .joinAtPane(let destination, let pane, let edge):
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                    _ = store.joinTabs(tabID, into: destination, beside: pane, edge: edge)
                }
            }
        } else if let outsidePoint {
            _ = store.onNewWindowDrop?(tabID, nil, outsidePoint)
        } else if !wasDragging, bounds.contains(convert(event.locationInWindow, from: nil)) {
            if event.modifierFlags.contains(.option) { store.toggleTabPinned(tabID) }
            else { store.select(tabID) }
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
        if dragSurface != nil, store?.tabReorderPreview.draggedID == tabID {
            store?.tabReorderPreview.draggedID = nil
        }
        let wasDragging = dragSurface != nil
        mouseDownPoint = nil
        dragSurface?.clearPlacement()
        dragSurface?.removeFromSuperview(); dragSurface = nil
        dragPreview?.close(); dragPreview = nil
        if wasDragging { window?.contentView?.layoutSubtreeIfNeeded() }
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
    private(set) var floatingRow: NSView?
    private var grabPoint: NSPoint = .zero
    private let marker = CAShapeLayer()
    private let badge = NSTextField(labelWithString: "")
    private(set) var placement: Placement? {
        didSet {
            if placement != nil { WindowDragTarget.reveal(window, from: source?.window) }
        }
    }
    private(set) var paneTarget: PaneDropHost?
    private weak var previewStore: BrowserStore?
    private enum HoverTarget: Equatable {
        case destination(UUID)
        case returnToSource
    }
    private var hoverTarget: HoverTarget?
    var isReturningToSource: Bool { hoverTarget == .returnToSource }
    private var hoverTask: Task<Void, Never>?
    private var previewedSourceWindowTab: UUID?
    var destinationStore: BrowserStore? { (window as? BrowseWindow)?.browserStore ?? source?.store }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init(source: TabDragSourceView, content: NSView) {
        self.source = source
        super.init(frame: content.bounds)
        autoresizingMask = [.width, .height]; wantsLayer = true
        marker.fillColor = NSColor.systemBlue.withAlphaComponent(0.22).cgColor
        marker.strokeColor = NSColor.systemBlue.cgColor
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
        if let store = source.store, let tab = store.sidebarTabs.first(where: { $0.id == source.tabID }),
           let row = descendants(of: PaneSidebarTargetView.self, in: content).first(where: { $0.destination == .tab(tab.id) }),
           let down = source.mouseDownPoint {
            let frame = row.convert(row.bounds, to: nil)
            grabPoint = NSPoint(x: down.x - frame.minX, y: frame.maxY - down.y)
            let preview = SidebarTabRow.dragPreview(store: store, tab: tab)
            preview.frame.size = frame.size
            floatingRow = preview
            addSubview(preview)
            store.tabReorderPreview.draggedID = tab.id
        }
        addSubview(badge)
    }
    required init?(coder: NSCoder) { return nil }

    func update(at windowPoint: NSPoint) {
        guard let source, let sourceStore = source.store, let sourceWindow = source.window,
              sourceStore.session.workspaces.flatMap(\.tabs).contains(where: { $0.id == source.tabID }),
              let windowPoint = WindowDragTarget.mount(self, from: sourceWindow, store: sourceStore, at: windowPoint),
              let store = destinationStore, let content = superview else {
            isHidden = true; clearPlacement(); return
        }
        if previewStore !== store {
            previewStore?.tabReorderPreview.clear()
            updateHover(nil)
            previewStore = store
        }
        let point = convert(windowPoint, from: nil)
        floatingRow?.isHidden = window !== sourceWindow
        floatingRow?.setFrameOrigin(NSPoint(x: point.x - grabPoint.x, y: point.y - grabPoint.y))
        badge.isHidden = window !== sourceWindow || floatingRow != nil
        badge.setFrameOrigin(NSPoint(x: point.x + 12, y: point.y + 12))
        guard bounds.contains(point) else { clearPlacement(); return }
        let targets = descendants(of: PaneSidebarTargetView.self, in: content).filter { $0.store === store && !$0.isHiddenOrHasHiddenAncestor }
        guard targets.contains(where: {
            if case .workspace = $0.destination {
                return $0.bounds.intersection($0.visibleRect).contains($0.convert(windowPoint, from: nil))
            }
            return false
        }) else {
            store.tabReorderPreview.clear()
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
        guard !rows.isEmpty else { clearPlacement(); return }
        // Reorder boundaries stay fixed, but a join belongs to the row the user sees.
        let stride = Chrome.sidebarTabHeight + Chrome.sidebarTabSpacing
        let joinRows = rows.map { id, bounds in
            (id, bounds.offsetBy(dx: 0, dy: CGFloat(store.tabReorderPreview.offsets[id, default: 0]) * stride))
        }
        let center = joinRows.first { $0.0 != source.tabID && $0.1.insetBy(dx: 0, dy: $0.1.height * 0.2).contains(point) }
        if let center {
            updateHover(.destination(center.0))
        } else if store === sourceStore, previewedSourceWindowTab == store.session.selectedTab {
            updateHover(.returnToSource)
        } else {
            updateHover(nil)
        }
        if let row = center {
            placement = .join(tabID: row.0)
            badge.isHidden = window !== sourceWindow
            badge.stringValue = "Join tabs"
            CATransaction.begin(); CATransaction.setDisableActions(true)
            marker.path = CGPath(roundedRect: row.1.insetBy(dx: 1, dy: 1),
                                 cornerWidth: 12, cornerHeight: 12, transform: nil)
            marker.isHidden = false
            CATransaction.commit()
            return
        }
        guard let sourceID = source.tabID else { clearPlacement(); return }
        marker.isHidden = true
        badge.isHidden = true
        let candidates = rows.filter { $0.0 != sourceID }
        guard let last = candidates.last else { placement = nil; return }
        let before = candidates.first { point.y < $0.1.midY }
        let target = before ?? last
        let next = Placement.reorder(tabID: target.0, after: before == nil)
        if placement != next {
            store.tabReorderPreview.show(tabs: store.sidebarTabs, source: sourceID, target: target.0, after: before == nil)
        }
        placement = next
        badge.stringValue = source.title
    }

    private func updateHover(_ target: HoverTarget?) {
        guard target != hoverTarget else { return }
        hoverTask?.cancel(); hoverTask = nil
        hoverTarget = target
        guard let target, let store = destinationStore else { return }
        hoverTask = Task { @MainActor [weak self, weak store] in
            let delay: Duration = target == .returnToSource ? .milliseconds(500) : .milliseconds(400)
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, let store, self.hoverTarget == target, self.source?.dragSurface === self,
                  let sourceID = self.source?.tabID,
                  self.source?.store?.session.workspaces.flatMap(\.tabs).contains(where: { $0.id == sourceID }) == true else { return }
            guard case .destination(let id) = target else {
                guard store === self.source?.store, store.session.selectedTab == self.previewedSourceWindowTab else { return }
                self.previewedSourceWindowTab = nil
                store.select(sourceID)
                return
            }
            guard store.session.workspaces.flatMap(\.tabs).contains(where: { $0.id == id }) else { return }
            guard self.placement == .join(tabID: id) else { return }
            if store.session.selectedTab != id {
                InputDiagnostics.transition(.tabHoverSelection, .changed, view: self.source, tabID: id)
                store.select(id)
            }
            if self.source?.store === store { self.previewedSourceWindowTab = id }
            store.zoomedPane = nil
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
            if store === source?.store { previewedSourceWindowTab = store.selectedTab.id }
            placement = .joinAtPane(tabID: store.selectedTab.id, paneID: pane, edge: edge)
            badge.isHidden = window !== source?.window
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
        previewStore?.tabReorderPreview.clear()
        previewStore = nil
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
