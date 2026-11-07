import AppKit

// @lat: [[architecture#Pane drag and drop]]
@MainActor
class BrowseWindow: NSWindow {
    weak var browserStore: BrowserStore?
    private(set) var dispatchingNativeMouseDown = false
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
        InputDiagnostics.record(.window, event: event)
        switch event.type {
        case .leftMouseDown:
            cancelPaneDrag()
            paneGesture = .idle
            // Floating chrome occludes native pane/window drag regions below it.
            if FloatingSidebarTrackingView.covers(event.locationInWindow, in: self) {
                forwardToAppKit(event)
                return
            }
            if let source = paneHandle(at: event.locationInWindow) {
                InputDiagnostics.transition(.paneOwnership, .started, event: event, view: source)
                if !isKeyWindow { makeKeyAndOrderFront(nil) }
                source.mouseDown(with: event)
                if source.mouseDownPoint != nil && source.window === self {
                    paneGesture = .tracking(source)
                    source.trackingWindow = self
                } else {
                    source.cancelDrag()
                    paneGesture = .awaitingRelease
                }
                InputDiagnostics.record(.paneConsumed, event: event, view: source)
                return
            }
        case .leftMouseDragged:
            if capturesPaneGesture {
                InputDiagnostics.record(.paneConsumed, event: event, view: activePaneDrag)
                activePaneDrag?.mouseDragged(with: event)
                return
            }
        case .leftMouseUp:
            if capturesPaneGesture {
                InputDiagnostics.record(.paneConsumed, event: event, view: activePaneDrag)
                // Release ownership before the drop can rebuild either tab.
                let source = activePaneDrag
                paneGesture = .idle
                InputDiagnostics.transition(.paneOwnership, .finished, event: event, view: source, window: self)
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
    func forwardToAppKit(_ event: NSEvent) {
        InputDiagnostics.record(.appKit, event: event)
        let previous = dispatchingNativeMouseDown
        dispatchingNativeMouseDown = event.type == .leftMouseDown
        defer {
            dispatchingNativeMouseDown = previous
            InputDiagnostics.record(.appKitReturned, event: event)
        }
        super.sendEvent(event)
    }

    func releasePaneDrag(_ source: PaneDragSourceView) {
        if activePaneDrag === source {
            paneGesture = .awaitingRelease
            InputDiagnostics.transition(.paneOwnership, .cancelled, view: source, window: self)
        }
    }

    private func cancelPaneDrag() {
        let source = activePaneDrag
        if capturesPaneGesture { InputDiagnostics.transition(.paneOwnership, .cancelled, view: source, window: self) }
        if capturesPaneGesture { paneGesture = .awaitingRelease }
        source?.cancelDrag()
    }

    override func becomeKey() {
        super.becomeKey()
        InputDiagnostics.transition(.windowKey, .started, window: self)
    }
    override func resignKey() {
        InputDiagnostics.transition(.windowKey, .finished, window: self)
        cancelPaneDrag(); super.resignKey()
    }
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        InputDiagnostics.transition(.firstResponder, .requested, view: responder as? NSView, window: self)
        let accepted = super.makeFirstResponder(responder)
        InputDiagnostics.transition(.firstResponder, accepted ? .allowed : .denied, view: responder as? NSView, window: self)
        return accepted
    }
    override func close() {
        InputDiagnostics.transition(.windowClose, .started, window: self)
        cancelPaneDrag(); paneGesture = .idle; super.close()
    }

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
