import AppKit
import SwiftUI

// @lat: [[architecture#Window dragging]]
struct WindowDragArea: NSViewRepresentable {
    var excluded = false
    var onPress: (() -> Void)?

    func makeNSView(context: Context) -> WindowDragAreaView { WindowDragAreaView() }
    func updateNSView(_ view: WindowDragAreaView, context: Context) {
        view.excluded = excluded
        view.onPress = onPress
    }
}

@MainActor
final class WindowDragAreaView: NSView {
    var excluded = false
    var onPress: (() -> Void)?
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // The sidebar overlay only claims presses. Scroll, hover, and other
        // events must hit the underlying SwiftUI scroll view and controls.
        guard !excluded, let window = window as? BrowseWindow,
              window.dispatchingNativeMouseDown else { return nil }
        let local = convert(point, from: superview)
        guard bounds.intersection(visibleRect).contains(local),
              Self.find(at: convert(local, to: nil), in: window) === self else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        // NSWindow.sendEvent must process the activating click before we start
        // dragging. Calling performDrag directly from our window's sendEvent
        // override skips AppKit's native activation/appearance bookkeeping.
        guard let window else { return }
        onPress?()
        window.performDrag(with: event)
    }

    static func find(at point: NSPoint, in window: NSWindow) -> WindowDragAreaView? {
        guard let content = window.contentView else { return nil }
        // Native traffic lights sit above the full-size SwiftUI content.
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            if let button = window.standardWindowButton(kind), !button.isHiddenOrHasHiddenAncestor,
               button.bounds.contains(button.convert(point, from: nil)) { return nil }
        }
        var area: WindowDragAreaView?
        var excluded = false
        func visit(_ view: NSView) {
            guard !view.isHiddenOrHasHiddenAncestor else { return }
            if let marker = view as? WindowDragAreaView,
               marker.bounds.intersection(marker.visibleRect).contains(marker.convert(point, from: nil)) {
                if marker.excluded { excluded = true }
                else { area = marker }
            }
            for child in view.subviews { visit(child) }
        }
        visit(content)
        return excluded ? nil : area
    }
}
