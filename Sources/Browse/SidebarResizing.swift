import AppKit
import SwiftUI

// @lat: [[architecture#Sidebar sizing]]
struct SidebarResizeHandle: NSViewRepresentable {
    let store: BrowserStore
    func makeNSView(context: Context) -> SidebarResizeView { SidebarResizeView() }
    func updateNSView(_ view: SidebarResizeView, context: Context) { view.store = store }
}

@MainActor
final class SidebarResizeView: NSView {
    weak var store: BrowserStore?
    private var startX: CGFloat?
    private var startWidth: CGFloat = 0
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        let rect = bounds.intersection(visibleRect)
        guard window != nil, !isHiddenOrHasHiddenAncestor, !rect.isEmpty,
              rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite else { return }
        addCursorRect(rect, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        InputDiagnostics.record(.sidebarResize, event: event, view: self)
        InputDiagnostics.transition(.sidebarResizeLifetime, .started, view: self)
        startX = event.locationInWindow.x
        startWidth = store?.sidebarWidth ?? BrowserStore.defaultSidebarWidth
    }

    override func mouseDragged(with event: NSEvent) {
        InputDiagnostics.record(.sidebarResize, event: event, view: self)
        guard let startX else { return }
        // Window coordinates stay fixed while this handle moves with the edge.
        store?.resizeSidebar(to: startWidth + event.locationInWindow.x - startX)
    }

    override func mouseUp(with event: NSEvent) {
        InputDiagnostics.record(.sidebarResize, event: event, view: self)
        mouseDragged(with: event)
        InputDiagnostics.transition(.sidebarResizeLifetime, .finished, view: self)
        startX = nil
    }

    override func cancelOperation(_ sender: Any?) {
        InputDiagnostics.transition(.sidebarResizeLifetime, .cancelled, view: self)
        startX = nil
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        InputDiagnostics.transition(.sidebarResizeLifetime, window == nil ? .detached : .attached, view: self)
        if window == nil { startX = nil }
    }
}
