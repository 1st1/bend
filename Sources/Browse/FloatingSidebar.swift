import AppKit
import SwiftUI

// @lat: [[architecture#Floating sidebar]]
struct FloatingSidebarTracking: NSViewRepresentable {
    let store: BrowserStore

    func makeNSView(context: Context) -> FloatingSidebarTrackingView { FloatingSidebarTrackingView() }
    func updateNSView(_ view: FloatingSidebarTrackingView, context: Context) { view.store = store }
    static func dismantleNSView(_ view: FloatingSidebarTrackingView, coordinator: ()) { view.stopTracking() }
}

@MainActor
final class FloatingSidebarTrackingView: NSView {
    static let inset: CGFloat = 6
    weak var store: BrowserStore?
    private var area: NSTrackingArea?
    private var dismissal: Task<Void, Never>?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var panelRect: NSRect {
        guard let store else { return .zero }
        return NSRect(x: Self.inset, y: Self.inset, width: store.sidebarWidth,
                      height: max(0, bounds.height - 2 * Self.inset))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let next = NSTrackingArea(rect: .zero,
            options: [.inVisibleRect, .activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved],
            owner: self, userInfo: nil)
        addTrackingArea(next)
        area = next
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowResigned),
                name: NSWindow.didResignKeyNotification, object: window)
        } else { stopTracking() }
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseMoved(with event: NSEvent) {
        // The tracking area's activeInKeyWindow policy gates real hover events.
        guard let store, !store.sidebarVisible, window != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        let edge = NSRect(x: 0, y: panelRect.minY, width: 13, height: panelRect.height)
        // Include the small gap to the window edge so crossing it never dismisses the panel.
        let retained = panelRect.insetBy(dx: -Self.inset, dy: -Self.inset)
        if edge.contains(point) || (store.sidebarFloating && retained.contains(point)) {
            dismissal?.cancel(); dismissal = nil
            if !store.sidebarFloating { store.sidebarFloating = true }
        } else { dismissSoon() }
    }

    override func mouseExited(with event: NSEvent) { dismissSoon() }

    private func dismissSoon() {
        guard store?.sidebarFloating == true, dismissal == nil else { return }
        dismissal = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            self?.store?.sidebarFloating = false
            self?.dismissal = nil
        }
    }

    @objc private func windowResigned(_ notification: Notification) { stopTracking() }

    func stopTracking() {
        dismissal?.cancel(); dismissal = nil
        if store?.sidebarFloating == true { store?.sidebarFloating = false }
    }

    static func covers(_ point: NSPoint, in window: NSWindow) -> Bool {
        func visit(_ view: NSView) -> Bool {
            guard !view.isHiddenOrHasHiddenAncestor else { return false }
            if let tracker = view as? FloatingSidebarTrackingView,
               tracker.store?.sidebarVisible == false, tracker.store?.sidebarFloating == true {
                return tracker.panelRect.contains(tracker.convert(point, from: nil))
            }
            return view.subviews.contains(where: visit)
        }
        return window.contentView.map(visit) ?? false
    }
}
