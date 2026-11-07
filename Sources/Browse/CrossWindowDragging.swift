import AppKit
import BrowseCore

enum WindowDropPlacement {
    case insert(relativeTo: UUID, after: Bool)
    case workspace(UUID)
    case join(tab: UUID, pane: UUID?, edge: PaneDropEdge)
}

@MainActor
enum WindowDragTarget {
    static func reveal(_ target: NSWindow?, from source: NSWindow?) {
        guard let target, let source, target !== source else { return }
        // Changing the key window would cancel the source's captured gesture.
        // Raise only the visual stacking order until the drop completes.
        if NSApp.orderedWindows.first !== target { target.orderFront(nil) }
    }

    // Mouse events remain owned by the pressed window throughout a drag.
    // Convert through screen coordinates before moving the visual overlay.
    static func resolve(from source: NSWindow, at point: NSPoint) -> BrowseWindow? {
        let screenPoint = source.convertPoint(toScreen: point)
        guard let target = NSApp.orderedWindows.first(where: {
            $0.isVisible && $0.frame.contains(screenPoint)
        }) as? BrowseWindow else { return nil }
        // AppKit owns this gesture locally. While active, also reject windows
        // covered by another application rather than dropping through them.
        if NSApp.isActive {
            let number = NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0)
            if number != 0 && number != target.windowNumber { return nil }
        }
        return target
    }

    static func mount(_ surface: NSView, from source: NSWindow, store: BrowserStore, at point: NSPoint) -> NSPoint? {
        guard let target = resolve(from: source, at: point), let content = target.contentView,
              target === source || target.browserStore?.preferencesStore === store.preferencesStore else { return nil }
        if surface.superview !== content {
            surface.removeFromSuperview()
            surface.frame = content.bounds
            content.addSubview(surface, positioned: .above, relativeTo: nil)
        }
        surface.isHidden = false
        return target.convertPoint(fromScreen: source.convertPoint(toScreen: point))
    }
}
