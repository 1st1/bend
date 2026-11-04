import AppKit

// @lat: [[architecture#Pane drag and drop]]
@MainActor
class BrowseWindow: NSWindow {
    private enum PaneGesture {
        case idle
        case tracking(PaneDragSourceView)
        case awaitingRelease
    }
    private var paneGesture: PaneGesture = .idle
    var activePaneDrag: PaneDragSourceView? {
        if case .tracking(let source) = paneGesture { return source }
        return nil
    }
    var capturesPaneGesture: Bool {
        if case .idle = paneGesture { return false }
        return true
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            cancelPaneDrag()
            paneGesture = .idle
            if let source = paneHandle(at: event.locationInWindow) {
                if !isKeyWindow { makeKeyAndOrderFront(nil) }
                source.mouseDown(with: event)
                if source.mouseDownPoint != nil && source.window === self {
                    paneGesture = .tracking(source)
                    source.trackingWindow = self
                } else {
                    source.cancelDrag()
                    paneGesture = .awaitingRelease
                }
                return
            }
        case .leftMouseDragged:
            if capturesPaneGesture {
                activePaneDrag?.mouseDragged(with: event)
                return
            }
        case .leftMouseUp:
            if capturesPaneGesture {
                // Release ownership before the drop can rebuild either tab.
                let source = activePaneDrag
                paneGesture = .idle
                source?.mouseUp(with: event)
                return
            }
        case .keyDown where event.keyCode == 53 && capturesPaneGesture:
            cancelPaneDrag()
            return
        default: break
        }
        forwardToAppKit(event)
    }

    // Pane presses, motion, and releases are all consumed by this window.
    // AppKit never starts native view tracking for a pane gesture, so hiding or
    // replacing its source cannot leave an obsolete native mouse target behind.
    func forwardToAppKit(_ event: NSEvent) { super.sendEvent(event) }

    func releasePaneDrag(_ source: PaneDragSourceView) {
        if activePaneDrag === source { paneGesture = .awaitingRelease }
    }

    private func cancelPaneDrag() {
        let source = activePaneDrag
        if capturesPaneGesture { paneGesture = .awaitingRelease }
        source?.cancelDrag()
    }

    override func resignKey() { cancelPaneDrag(); super.resignKey() }
    override func close() { cancelPaneDrag(); paneGesture = .idle; super.close() }

    private func paneHandle(at point: NSPoint) -> PaneDragSourceView? {
        guard let contentView else { return nil }
        func find(in view: NSView) -> PaneDragSourceView? {
            guard !view.isHiddenOrHasHiddenAncestor else { return nil }
            if let source = view as? PaneDragSourceView {
                guard source.window === self, let store = source.store,
                      source.tabID == store.selectedTab.id,
                      store.selectedTab.pages.contains(where: { $0.id == source.pageID }),
                      source.bounds.intersection(source.visibleRect).contains(source.convert(point, from: nil)) else { return nil }
                return source
            }
            for child in view.subviews.reversed() {
                if let source = find(in: child) { return source }
            }
            return nil
        }
        return find(in: contentView)
    }
}
