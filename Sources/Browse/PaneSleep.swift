import AppKit
import WebKit
import BrowseCore

// @lat: [[lat.md/architecture/pane-sleep#Automatic pane sleeping]]
struct PaneSleepPolicy {
    enum Pressure { case normal, warning, critical }
    static func timeout(lowPower: Bool, pressure: Pressure) -> TimeInterval {
        switch pressure {
        case .critical: 60
        case .warning: 300
        case .normal: lowPower ? 600 : 1800
        }
    }
}

@MainActor
struct PaneRestorationState {
    let interactionState: Any
    let snapshot: Data?
    let address: String
    let title: String
    let zoom: CGFloat
    let closeHistoryURL: URL?
}

// A callback may never arrive from an unresponsive content process. A deadline
// returns unknown, without keeping the sweep waiting for an eligibility reply.
@MainActor
private final class SleepReply<Value: Sendable> {
    private var continuation: CheckedContinuation<Value?, Never>?
    private var timeout: Task<Void, Never>?
    init(_ continuation: CheckedContinuation<Value?, Never>, seconds: Double) {
        self.continuation = continuation
        timeout = Task { [self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            self.finish(nil)
        }
    }
    func finish(_ value: Value?) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel(); timeout = nil
        continuation.resume(returning: value)
    }
}

@MainActor
func sleepReply<Value: Sendable>(seconds: Double = 3, _ start: (@escaping @MainActor (Value?) -> Void) -> Void) async -> Value? {
    await withCheckedContinuation { continuation in
        let reply = SleepReply<Value>(continuation, seconds: seconds)
        start { reply.finish($0) }
    }
}

@MainActor
final class PaneSleepCoordinator {
    private static var checking = false
    private static let pendingSnapshots = NSHashTable<WKWebView>.weakObjects()
    private weak var store: BrowserStore?
    private var timer: Timer?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var sweep: Task<Void, Never>?
    private(set) var lastVisible: [UUID: TimeInterval] = [:]
    private var revision = 0
    private var stopped = false
    var pressure: PaneSleepPolicy.Pressure = .normal

    init(store: BrowserStore) { self.store = store }

    isolated deinit { timer?.invalidate(); pressureSource?.cancel(); sweep?.cancel() }

    func start() {
        if let store {
            let now = ProcessInfo.processInfo.systemUptime
            for tab in store.session.workspaces.flatMap(\.tabs) {
                for page in tab.pages where store.existingController(for: page.id) != nil { didCreate(page.id, now: now) }
            }
        }
        noteVisible()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.schedule() }
        }
        timer?.tolerance = 10
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            let data = source?.data
            Task { @MainActor in
                guard let self else { return }
                self.pressure = data?.contains(.critical) == true ? .critical : (data?.contains(.warning) == true ? .warning : .normal)
                self.schedule()
            }
        }
        pressureSource = source
        source.resume()
    }

    func noteVisible(previous: BrowserSession? = nil, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard let store else { return }
        revision += 1
        let tabs = store.session.workspaces.flatMap(\.tabs)
        let ids = Set(tabs.flatMap(\.pages).map(\.id))
        lastVisible = lastVisible.filter { ids.contains($0.key) }
        if let previous, previous.selectedTab != store.session.selectedTab {
            for page in previous.workspaces.flatMap(\.tabs).first(where: { $0.id == previous.selectedTab })?.pages ?? [] {
                if ids.contains(page.id) { lastVisible[page.id] = now }
            }
        }
        for page in tabs.first(where: { $0.id == store.session.selectedTab })?.pages ?? [] { lastVisible[page.id] = now }
    }

    func didCreate(_ id: UUID, now: TimeInterval = ProcessInfo.processInfo.systemUptime) { lastVisible[id] = now }

    func stop() {
        stopped = true; revision += 1
        timer?.invalidate(); timer = nil
        pressureSource?.cancel(); pressureSource = nil
        sweep?.cancel(); sweep = nil
    }

    private func schedule() {
        guard !stopped, sweep == nil else { return }
        sweep = Task { [weak self] in
            await self?.run()
            self?.sweep = nil
        }
    }

    func run(now: TimeInterval = ProcessInfo.processInfo.systemUptime, lowPower: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled) async {
        guard !stopped, let store else { return }
        let timeout = PaneSleepPolicy.timeout(lowPower: lowPower, pressure: pressure)
        let candidates = store.session.workspaces.flatMap(\.tabs).flatMap(\.pages).map(\.id)
            .sorted { (lastVisible[$0] ?? now) < (lastVisible[$1] ?? now) }
        for id in candidates {
            guard !stopped, !Task.isCancelled else { return }
            guard now - (lastVisible[id] ?? now) >= timeout else { continue }
            await suspend(id)
        }
    }

    // One candidate at a time. No controller, WebView, or image is retained in
    // sleeping state, and no snapshot is requested before the safety checks.
    func suspend(_ id: UUID) async {
        guard !stopped, !Self.checking,
              let store, let controller = store.sleepCandidate(id),
              !Self.pendingSnapshots.contains(controller.webView) else { return }
        Self.checking = true
        defer { Self.checking = false }
        let attempt = revision, navigation = controller.sleepNavigationRevision
        let web = controller.webView
        let url = web.url
        func eligible() -> Bool {
            !stopped && !Task.isCancelled && revision == attempt &&
            store.sleepCandidate(id) === controller && controller.webView === web &&
            controller.sleepNavigationRevision == navigation && web.url == url
        }
        guard await playbackIsIdle(web), eligible(),
              let document = await PaneSleepProbe.check(web), eligible() else { return }
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = 640
        Self.pendingSnapshots.add(web)
        guard let image: NSImage = await sleepReply({ done in
            web.takeSnapshot(with: config) { [weak web] image, error in
                if let web { Self.pendingSnapshots.remove(web) }
                done(error == nil ? image : nil)
            }
        }), eligible(), let bitmap = image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)),
              let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.65]),
              await playbackIsIdle(web), eligible(),
              await PaneSleepProbe.check(web) == document, eligible(),
              let state = controller.restorationState(snapshot: data) else { return }
        store.finishSleeping(id, controller: controller, state: state)
    }

    private func playbackIsIdle(_ web: WKWebView) async -> Bool {
        let state: WKMediaPlaybackState? = await sleepReply { done in web.requestMediaPlaybackState { done($0) } }
        return state == .some(.none) || state == .some(.paused)
    }
}
