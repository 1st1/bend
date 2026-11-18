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

    private final class WeakBox<Object: AnyObject> {
        weak var value: Object?
        init(_ value: Object) { self.value = value }
    }

    static var active: TabPerformanceCounters?
    private let stores: [WeakBox<BrowserStore>]
    private let windows: [WeakBox<NSWindow>]
    private(set) var counts = Counts()

    convenience init(store: BrowserStore, window: NSWindow) {
        self.init(stores: [store], windows: [window])
    }

    init(stores: [BrowserStore], windows: [NSWindow]) {
        self.stores = stores.map(WeakBox.init)
        self.windows = windows.map(WeakBox.init)
    }

    static func record(_ counter: WritableKeyPath<Counts, Int>, store: BrowserStore) {
        guard let active, active.stores.contains(where: { $0.value === store }) else { return }
        active.counts[keyPath: counter] += 1
    }

    static func record(_ counter: WritableKeyPath<Counts, Int>, window: NSWindow?) {
        guard let window, let active, active.windows.contains(where: { $0.value === window }) else { return }
        active.counts[keyPath: counter] += 1
    }
}
#endif
