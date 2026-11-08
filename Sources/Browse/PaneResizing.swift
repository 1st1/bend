import AppKit
import SwiftUI
import BrowseCore

// @lat: [[architecture#Pane layout animation]]
struct PaneDivider: NSViewRepresentable {
    let placement: DividerPlacement
    let paneIDs: [UUID]
    let tabID: UUID
    let onResize: (Double) -> Void

    func makeNSView(context: Context) -> PaneDividerView { PaneDividerView() }
    func updateNSView(_ view: PaneDividerView, context: Context) {
        view.placement = placement
        view.paneIDs = paneIDs
        view.tabID = tabID
        view.onResize = onResize
    }
    static func dismantleNSView(_ view: PaneDividerView, coordinator: ()) { view.cancelOperation(nil) }
}

@MainActor
final class PaneDividerView: NSView {
    var placement: DividerPlacement?
    var paneIDs: [UUID] = []
    var tabID: UUID?
    var onResize: ((Double) -> Void)?
    private var startPoint: NSPoint?
    private var startLength: CGFloat = 0
    private var cursorTracking: NSTrackingArea?
    var resizeCursor: NSCursor { placement?.axis == .horizontal ? .resizeLeftRight : .resizeUpDown }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        let rect = bounds.intersection(visibleRect)
        guard window != nil, !isHiddenOrHasHiddenAncestor, !rect.isEmpty,
              rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite else { return }
        addCursorRect(rect, cursor: resizeCursor)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTracking { removeTrackingArea(cursorTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        cursorTracking = area
    }
    override func cursorUpdate(with event: NSEvent) { resizeCursor.set() }
    override func mouseEntered(with event: NSEvent) { resizeCursor.set() }

    override func mouseDown(with event: NSEvent) {
        guard let placement else { return }
        startPoint = event.locationInWindow
        startLength = placement.firstLength
        for pane in paneIDs { InputDiagnostics.transition(.dividerResize, .started, paneID: pane, tabID: tabID) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let startPoint, let placement else { return }
        resizeCursor.set()
        // Window coordinates remain stable as this divider moves with the split.
        let delta = placement.axis == .horizontal
            ? event.locationInWindow.x - startPoint.x : startPoint.y - event.locationInWindow.y
        onResize?(placement.fraction(forLength: startLength + delta))
    }
    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        finish()
    }
    override func cancelOperation(_ sender: Any?) { finish() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { finish() }
    }
    private func finish() {
        guard startPoint != nil else { return }
        for pane in paneIDs { InputDiagnostics.transition(.dividerResize, .finished, paneID: pane, tabID: tabID) }
        startPoint = nil
    }
}
