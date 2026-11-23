import AppKit
import SwiftUI
import WebKit
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
        InputDiagnostics.transition(.paneHandleLifetime, .removed, view: view, tabID: view.tabID)
        view.clearTitlePreview()
        view.onHover = nil
        view.cancelDrag()
    }
    func updateNSView(_ view: PaneDragSourceView, context: Context) {
        let changed = view.pageID != pageID
        if changed { view.clearTitlePreview() }
        view.store = store; view.tabID = tabID; view.pageID = pageID; view.title = title
        if changed { InputDiagnostics.transition(.paneHandleLifetime, .created, view: view, tabID: tabID) }
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
    private weak var titlePreviewHost: WebSurfaceHost?
    private var hoverTracking: NSTrackingArea?
    private(set) var isHovering = false
    private(set) var mouseDownPoint: NSPoint?
    private(set) var dragSurface: PaneDragSurface?
    private(set) var dragPreview: DetachedDragPreview?
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
        clearTitlePreview()
        if hovering, let pageID, let controller = store?.existingController(for: pageID),
           !controller.isStartPage, controller.error == nil,
           let host = controller.webView.superview as? WebSurfaceHost {
            titlePreviewHost = host
            host.showTitlePreview(controller.address)
        }
        onHover?(hovering)
    }

    func clearTitlePreview() {
        titlePreviewHost?.showTitlePreview("")
        titlePreviewHost = nil
    }

    override func viewDidHide() {
        super.viewDidHide()
        setHovering(false)
    }

    override func mouseEntered(with event: NSEvent) { setHovering(true) }
    override func mouseExited(with event: NSEvent) { setHovering(false) }

    override func mouseDown(with event: NSEvent) {
        clearTitlePreview()
        InputDiagnostics.record(.paneHandle, event: event, view: self)
        cancelDrag()
        guard let store, let tabID, let pageID, store.selectedTab.id == tabID else { return }
        store.focus(pageID)
        mouseDownPoint = event.locationInWindow
        InputDiagnostics.transition(.paneDrag, .requested, event: event, view: self, tabID: tabID)
    }

    override func mouseDragged(with event: NSEvent) {
        InputDiagnostics.record(.paneHandle, event: event, view: self)
        guard let origin = mouseDownPoint, let store, let tabID,
              store.session.workspaces.flatMap(\.tabs).contains(where: { $0.id == tabID && $0.pages.contains { $0.id == pageID } }),
              (dragSurface != nil || store.selectedTab.id == tabID),
              let window, let content = window.contentView else {
            cancelDrag(); return
        }
        guard dragSurface != nil || hypot(event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y) >= 5 else { return }
        if dragSurface == nil {
            if let tab = store.session.workspaces.flatMap(\.tabs).first(where: { $0.id == tabID }) {
                dragPreview = DetachedDragPreview(store: store, tab: tab, pane: pageID, title: title, source: window)
            }
            let surface = PaneDragSurface(source: self, content: content)
            dragSurface = surface
            InputDiagnostics.transition(.paneDrag, .started, event: event, view: self, tabID: tabID)
            content.addSubview(surface, positioned: .above, relativeTo: nil)

        }
        dragSurface?.update(at: event.locationInWindow)
        if dragSurface?.sidebarRow?.isHidden == false {
            dragPreview?.hide()
        } else {
            let screenPoint = window.convertPoint(toScreen: event.locationInWindow)
            dragPreview?.update(at: screenPoint, expanded: WindowDragTarget.previewExpanded(
                at: screenPoint, store: store, wasExpanded: dragPreview?.expanded == true))
        }
    }

    override func mouseUp(with event: NSEvent) {
        InputDiagnostics.record(.paneHandle, event: event, view: self)
        guard mouseDownPoint != nil else { return }
        dragSurface?.update(at: event.locationInWindow)
        let outsidePoint = dragSurface == nil ? nil
            : WindowDragTarget.newWindowPoint(from: window, at: event.locationInWindow, store: store)
        let target = dragSurface?.target
        let sidebarTarget = dragSurface?.sidebarTarget
        let insertion = dragSurface?.insertion
        let edge = target?.dropEdge
        let sourceID = target?.validSource(self)
        InputDiagnostics.transition(.paneDrop, .requested, event: event, view: self, tabID: target?.tabID, relatedPaneID: target?.pageID, flags: ["paneTarget": target != nil, "sidebarTarget": sidebarTarget != nil])
        cancelDrag()
        if let target, let edge, let sourceID, let store, let tabID, let targetID = target.pageID {
            if let destination = target.tabID {
                if let targetStore = target.store, targetStore !== store {
                    if store.transfer(tab: tabID, pane: sourceID, to: targetStore,
                                      at: .join(tab: destination, pane: targetID, edge: edge)) {
                        target.window?.makeKeyAndOrderFront(nil)
                    }
                } else {
                    store.movePane(sourceID, beside: targetID, edge: edge, in: destination, from: tabID)
                }
            }
        } else if let sidebarTarget, let store, let tabID, let pageID {
            if let insertion, let destination = sidebarTarget.store {
                if destination !== store {
                    if store.transfer(tab: tabID, pane: pageID, to: destination,
                                      at: .insert(relativeTo: insertion.id, after: insertion.after)) {
                        sidebarTarget.window?.makeKeyAndOrderFront(nil)
                    }
                } else if let workspace = store.session.workspaces.first(where: { $0.tabs.contains { $0.id == insertion.id } }) {
                    store.detachPane(pageID, from: tabID, into: workspace.id, relativeTo: insertion.id, after: insertion.after)
                }
                return
            }
            if let targetStore = sidebarTarget.store, targetStore !== store {
                let placement: WindowDropPlacement
                switch sidebarTarget.destination {
                case .tab(let id): placement = .join(tab: id, pane: targetStore.session.workspaces.flatMap(\.tabs).first { $0.id == id }?.focusedPane, edge: .right)
                case .workspace(let id): placement = .workspace(id)
                }
                if store.transfer(tab: tabID, pane: pageID, to: targetStore, at: placement) {
                    sidebarTarget.window?.makeKeyAndOrderFront(nil)
                }
                return
            }
            switch sidebarTarget.destination {
            case .tab(let destination) where destination != tabID:
                store.movePaneToTab(pageID, from: tabID, into: destination)
            case .workspace(let workspace):
                store.detachPane(pageID, from: tabID, into: workspace)
            default: break
            }
        } else if let outsidePoint, let store, let tabID, let pageID {
            _ = store.onNewWindowDrop?(tabID, pageID, outsidePoint)
        }
    }

    override func cancelOperation(_ sender: Any?) { cancelDrag() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        InputDiagnostics.transition(.paneHandleLifetime, window == nil ? .detached : .attached, view: self, tabID: tabID)
        if window == nil { cancelDrag(); setHovering(false) }
    }

    func cancelDrag() {
        if mouseDownPoint != nil || dragSurface != nil {
            InputDiagnostics.transition(.paneDrag, .finished, view: self, tabID: tabID, flags: ["surface": dragSurface != nil])
        }
        mouseDownPoint = nil
        dragSurface?.clearTargets()
        dragSurface?.removeFromSuperview()
        dragSurface = nil
        dragPreview?.close(); dragPreview = nil
        trackingWindow?.releasePaneDrag(self)
        trackingWindow = nil
    }


}

// Native pane geometry is used directly during an internal drag; WebKit's
// pasteboard destination and hit testing do not participate.
@MainActor
class PaneDropHost: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        InputDiagnostics.transition(.paneRoot, window == nil ? .detached : .attached, view: self, tabID: tabID)
    }
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        InputDiagnostics.transition(.paneRoot, superview == nil ? .detached : .attached, view: self, tabID: tabID, flags: ["superview": true])
    }
    override func viewDidHide() {
        super.viewDidHide()
        InputDiagnostics.transition(.paneVisibility, .hidden, view: self, tabID: tabID)
    }
    override func viewDidUnhide() {
        super.viewDidUnhide()
        InputDiagnostics.transition(.paneVisibility, .shown, view: self, tabID: tabID)
    }
    override var frame: NSRect {
        didSet {
            if frame != oldValue { InputDiagnostics.transition(.paneGeometry, .changed, view: self, tabID: tabID) }
        }
    }

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
    required init?(coder: NSCoder) { return nil }

    func validSource(_ source: PaneDragSourceView) -> UUID? {
        guard let store, let sourceStore = source.store, sourceStore.preferencesStore === store.preferencesStore,
              sourceStore === store || (!sourceStore.isPrivate && !store.isPrivate),
              let tabID, let sourceTabID = source.tabID,
              store.selectedTab.id == tabID, store.zoomedPane == nil,
              let sourceID = source.pageID, let pageID, sourceID != pageID,
              sourceStore.session.workspaces.flatMap(\.tabs).contains(where: { $0.id == sourceTabID && $0.pages.contains { $0.id == sourceID } }),
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
    private(set) var target: PaneDropHost?
    private var hoveredSidebar: PaneSidebarTargetView?
    private(set) var insertion: (id: UUID, after: Bool)?
    private weak var reorderStore: BrowserStore?
    var sidebarTarget: PaneSidebarTargetView? {
        if case .tab(let id) = hoveredSidebar?.destination, id == source?.tabID { return nil }
        return hoveredSidebar
    }
    private(set) var sidebarRow: NSView?
    private var liveCanvas: NSView?
    private weak var previousWebHost: WebSurfaceHost?
    private weak var previewWebView: WKWebView?
    private var hoverTask: Task<Void, Never>?
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init(source: PaneDragSourceView, content: NSView) {
        self.source = source
        super.init(frame: content.bounds)
        autoresizingMask = [.width, .height]
        wantsLayer = true
    }
    required init?(coder: NSCoder) { return nil }

    func update(at windowPoint: NSPoint) {
        guard let source, let sourceWindow = source.window, let sourceStore = source.store,
              let windowPoint = WindowDragTarget.mount(self, from: sourceWindow, store: sourceStore, at: windowPoint),
              let store = (window as? BrowseWindow)?.browserStore ?? source.store else {
            isHidden = true; clearTargets(); return
        }
        let point = convert(windowPoint, from: nil)
        guard bounds.contains(point), let content = superview else { clearTargets(); return }
        let targetsInSidebar = descendants(of: PaneSidebarTargetView.self, in: content).filter {
            $0.store === store && !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty
        }
        let sidebar = targetsInSidebar.filter {
            $0.bounds.intersection($0.visibleRect).contains($0.convert(windowPoint, from: nil))
        }
        // Rows take precedence over the containing workspace's empty-space target.
        var hovered = sidebar.first { if case .tab = $0.destination { return true }; return false }
            ?? sidebar.min { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
        var insertionFrame: NSRect?
        if let workspace = sidebar.first(where: { if case .workspace = $0.destination { return true }; return false }),
           let pageID = source.pageID {
            let rows = targetsInSidebar.compactMap { view -> (UUID, NSRect)? in
                guard case .tab(let id) = view.destination else { return nil }
                return (id, convert(view.bounds, from: view))
            }.sorted { $0.1.midY < $1.1.midY }
            // Keep the opened slot stable through mouse-up. Use the fixed row
            // bounds (outside TabReorderOffset) to locate the next boundary.
            if reorderStore === store, let frame = sidebarRow?.frame, insertion != nil,
               frame.contains(point) {
                insertionFrame = frame
            } else {
                clearInsertion()
                let stride = Chrome.sidebarTabHeight + Chrome.sidebarTabSpacing
                for (index, row) in rows.enumerated() {
                    let after = index == rows.count - 1 && point.y >= row.1.midY
                    let boundary = after ? row.1.maxY : row.1.minY
                    guard point.x >= row.1.minX, point.x <= row.1.maxX,
                          abs(point.y - boundary) <= Chrome.sidebarTabSpacing + row.1.height * 0.2 else { continue }
                    insertion = (row.0, after)
                    reorderStore = store
                    store.tabReorderPreview.show(tabs: store.sidebarTabs, source: pageID, target: row.0, after: after)
                    insertionFrame = row.1.offsetBy(dx: 0, dy: after ? stride : 0)
                    break
                }
            }
            if insertionFrame != nil { hovered = workspace }
        } else { clearInsertion() }
        if hoveredSidebar !== hovered {
            if liveCanvas?.window !== window { endLiveCanvas() }
            sidebarTarget?.showPreview(false)
            hoverTask?.cancel(); hoverTask = nil
            hoveredSidebar = hovered
            if let hovered, case .tab(let id) = hovered.destination,
               store.session.selectedTab != id {
                if id == source.tabID, store === sourceStore {
                    endLiveCanvas()
                    store.select(id)
                    store.zoomedPane = nil
                } else {
                    hoverTask = Task { @MainActor [weak self, weak store] in
                        do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
                        guard let self, self.hoveredSidebar === hovered, let store,
                              store.session.workspaces.flatMap(\.tabs).contains(where: { $0.id == id }) else { return }
                        self.endLiveCanvas()
                        InputDiagnostics.transition(.paneHoverSelection, .changed, view: self.source, tabID: id)
                        store.select(id)
                        store.zoomedPane = nil
                    }
                }
            }
        }
        if let hovered {
            setTarget(nil)
            WindowDragTarget.reveal(window, from: source.window)
            sidebarTarget?.showPreview(true)
            showSidebarRow(for: source, over: hovered, at: point)
            if let insertionFrame { sidebarRow?.frame = insertionFrame }
            switch hovered.destination {
            case .workspace:
                showLiveCanvas(for: source, in: content)
            case .tab(let id) where id != source.tabID && store.session.selectedTab != id:
                showLiveCanvas(for: source, in: content)
            default: endLiveCanvas()
            }
            return
        }
        sidebarRow?.isHidden = true
        endLiveCanvas()
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

    private func showSidebarRow(for source: PaneDragSourceView, over hovered: PaneSidebarTargetView, at point: NSPoint) {
        if sidebarRow == nil, let store = source.store,
           let tab = store.session.workspaces.flatMap(\.tabs).first(where: { $0.id == source.tabID }),
           let page = tab.pages.first(where: { $0.id == source.pageID }) {
            let row = SidebarTabRow.dragPreview(store: store, tab: BrowserTab(title: source.title, pages: [page]))
            addSubview(row)
            sidebarRow = row
        }
        var slot = convert(hovered.bounds, from: hovered)
        let height = Chrome.sidebarTabHeight
        switch hovered.destination {
        case .workspace:
            slot = slot.insetBy(dx: Chrome.sidebarHorizontalInset, dy: 0)
            slot.origin.y = point.y - height / 2
        case .tab:
            // Keep the highlighted merge destination visible above the dragged row.
            slot.origin.y = slot.maxY + Chrome.sidebarTabSpacing
        }
        slot.origin.y = max(bounds.minY, min(slot.minY, bounds.maxY - height))
        slot.size.height = height
        sidebarRow?.frame = slot
        sidebarRow?.isHidden = false
    }

    // Borrow the running WebView, not its controller or session entry. The
    // original pane and title handle stay mounted throughout AppKit tracking.
    private func showLiveCanvas(for source: PaneDragSourceView, in content: NSView) {
        guard liveCanvas == nil, let store = source.store, let pageID = source.pageID,
              let tab = store.session.workspaces.flatMap(\.tabs).first(where: { $0.id == source.tabID }),
              let page = tab.pages.first(where: { $0.id == pageID }),
              let controller = store.existingController(for: pageID),
              let canvas = descendants(of: MountedTabHost.self, in: content).first(where: { !$0.isHiddenOrHasHiddenAncestor })
        else { return }
        let standalone = BrowserTab(title: source.title, pages: [page])
        previousWebHost = controller.webView.superview as? WebSurfaceHost
        previewWebView = controller.webView
        let view = NSHostingView(rootView: BrowserPane(store: store, controller: controller, tab: standalone,
                                                       pageID: pageID, isDragCanvas: true)
            .background(Color(nsColor: .windowBackgroundColor)).allowsHitTesting(false).accessibilityHidden(true))
        liveCanvas = view
        view.sizingOptions = []
        view.safeAreaRegions = []
        view.frame = canvas.bounds
        view.autoresizingMask = [.width, .height]
        canvas.addSubview(view, positioned: .above, relativeTo: nil)
        view.layoutSubtreeIfNeeded()
    }

    private func endLiveCanvas() {
        guard let view = liveCanvas else { return }
        let borrowed = previewWebView.flatMap { $0.isDescendant(of: view) ? $0 : nil }
        view.removeFromSuperview()
        if let borrowed { previousWebHost?.restoreAfterDrag(borrowed) }
        liveCanvas = nil
        previousWebHost = nil
        previewWebView = nil
    }

    private func setTarget(_ next: PaneDropHost?, edge: PaneDropEdge? = nil) {
        if let next { WindowDragTarget.reveal(next.window, from: source?.window) }
        // Keep an unchanged target visible across pointer events. Clearing it
        // first lets an intermediate hidden layer reach the compositor.
        if target !== next {
            InputDiagnostics.transition(.paneDrop, .changed, view: source, tabID: next?.tabID, relatedPaneID: next?.pageID, flags: ["hasTarget": next != nil])
            target?.showPreview(nil); target = next
        }
        next?.showPreview(edge)
    }

    private func descendants<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        if view === self { return [] }
        return (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(of: type, in: $0) }
    }

    func clearTargets() {
        clearInsertion()
        endLiveCanvas()
        sidebarRow?.isHidden = true
        hoverTask?.cancel(); hoverTask = nil
        setTarget(nil)
        sidebarTarget?.showPreview(false); hoveredSidebar = nil
    }

    private func clearInsertion() {
        reorderStore?.tabReorderPreview.clear()
        reorderStore = nil
        insertion = nil
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
    required init?(coder: NSCoder) { return nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func showPreview(_ visible: Bool) {
        // Only merge destinations get an outline. The dragged row represents
        // a standalone tab over workspace space.
        let outline: Bool
        if case .tab = destination { outline = visible } else { outline = false }
        let rect = bounds.insetBy(dx: 1, dy: 1)
        if !outline, preview.isHidden { return }
        if outline, !preview.isHidden, rect == previewRect { return }
        previewRect = rect
        CATransaction.begin(); CATransaction.setDisableActions(true)
        preview.isHidden = !outline
        if outline { preview.path = CGPath(roundedRect: rect, cornerWidth: 12, cornerHeight: 12, transform: nil) }
        CATransaction.commit()
    }
}
