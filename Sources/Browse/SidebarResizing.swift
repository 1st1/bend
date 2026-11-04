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
        addCursorRect(bounds.intersection(visibleRect), cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        startX = event.locationInWindow.x
        startWidth = store?.sidebarWidth ?? 236
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startX else { return }
        // Window coordinates stay fixed while this handle moves with the edge.
        store?.resizeSidebar(to: startWidth + event.locationInWindow.x - startX)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        startX = nil
    }

    override func cancelOperation(_ sender: Any?) { startX = nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { startX = nil }
    }
}
