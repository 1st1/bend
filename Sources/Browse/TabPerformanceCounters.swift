#if DEBUG
import AppKit

@MainActor
final class TabPerformanceCounters {
    struct Counts: Encodable {
        var mountedRootReplacements = 0
        var browserPaneBodies = 0
        var sidebarRowBodies = 0
        var shadowInvalidations = 0
        var shadowGeometryInvalidations = 0
        var shadowDraws = 0
    }

    static var active: TabPerformanceCounters?
    private weak var store: BrowserStore?
    private weak var window: NSWindow?
    private(set) var counts = Counts()

    init(store: BrowserStore, window: NSWindow) {
        self.store = store
        self.window = window
    }

    static func record(_ counter: WritableKeyPath<Counts, Int>, store: BrowserStore) {
        guard let active, active.store === store else { return }
        active.counts[keyPath: counter] += 1
    }

    static func record(_ counter: WritableKeyPath<Counts, Int>, window: NSWindow?) {
        guard let window, let active, active.window === window else { return }
        active.counts[keyPath: counter] += 1
    }
}
#endif
