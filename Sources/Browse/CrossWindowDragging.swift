import AppKit
import BrowseCore

enum WindowDropPlacement {
    case insert(relativeTo: UUID, after: Bool)
    case workspace(UUID)
    case emptyWindow
    case join(tab: UUID, pane: UUID?, edge: PaneDropEdge)
}

@MainActor
enum WindowDragTarget {
    static func reveal(_ target: NSWindow?, from source: NSWindow?) {
        guard let target, let source, target !== source else { return }
        // Changing the key window would cancel the source's captured gesture.
        // Raise only the visual stacking order until the drop completes.
        if NSApp.orderedWindows.first(where: { !($0 is DetachedDragPanel) }) !== target { target.orderFront(nil) }
    }

    // Mouse events remain owned by the pressed window throughout a drag.
    // Convert through screen coordinates before moving the visual overlay.
    static func resolve(from source: NSWindow, at point: NSPoint) -> BrowseWindow? {
        let screenPoint = source.convertPoint(toScreen: point)
        guard let target = NSApp.orderedWindows.first(where: {
            $0.isVisible && !($0 is DetachedDragPanel) && $0.frame.contains(screenPoint)
        }) as? BrowseWindow else { return nil }
        // AppKit owns this gesture locally. While active, also reject windows
        // covered by another application rather than dropping through them.
        if NSApp.isActive {
            var number = NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0)
            let previews = Set(NSApp.windows.filter { $0 is DetachedDragPanel }.map(\.windowNumber))
            while previews.contains(number) {
                number = NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: number)
            }
            if number != 0 && number != target.windowNumber { return nil }
        }
        return target
    }

    static func canCreateWindow(at point: NSPoint, store: BrowserStore) -> Bool {
        guard store.onNewWindowDrop != nil, NSScreen.screens.contains(where: { $0.frame.contains(point) }) else { return false }
        return !NSApp.orderedWindows.contains { window in
            window is BrowseWindow && window.isVisible && window.frame.contains(point)
        }
    }

    static func previewExpanded(at point: NSPoint, store: BrowserStore, wasExpanded: Bool) -> Bool {
        guard store.onNewWindowDrop != nil, NSScreen.screens.contains(where: { $0.frame.contains(point) }) else { return false }
        // Keep the visual size stable within a small band around window edges.
        // Actual drop eligibility still uses the exact window bounds.
        let inset: CGFloat = wasExpanded ? 12 : -12
        return !NSApp.orderedWindows.contains { window in
            window is BrowseWindow && window.isVisible && window.frame.insetBy(dx: inset, dy: inset).contains(point)
        }
    }

    static func newWindowPoint(from source: NSWindow?, at point: NSPoint, store: BrowserStore?) -> NSPoint? {
        guard let source, let store else { return nil }
        let screenPoint = source.convertPoint(toScreen: point)
        return canCreateWindow(at: screenPoint, store: store) ? screenPoint : nil
    }

    static func mount(_ surface: NSView, from source: NSWindow, store: BrowserStore, at point: NSPoint) -> NSPoint? {
        guard let target = resolve(from: source, at: point), let content = target.contentView,
              target === source || (!store.isPrivate && target.browserStore?.isPrivate == false
                  && target.browserStore?.preferencesStore === store.preferencesStore) else { return nil }
        if surface.superview !== content {
            surface.removeFromSuperview()
            surface.frame = content.bounds
            content.addSubview(surface, positioned: .above, relativeTo: nil)
        }
        surface.isHidden = false
        return target.convertPoint(fromScreen: source.convertPoint(toScreen: point))
    }
}
