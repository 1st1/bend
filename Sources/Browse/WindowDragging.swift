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
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

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
