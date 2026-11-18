#if DEBUG
import AppKit
import BrowseCore
import Darwin
import os
import SwiftUI
import Testing
import WebKit
@testable import Browse

@Suite(.serialized)
@MainActor
struct TabPerformanceTests {
    // @lat: [[lat.md/tests/session-tests#Tab performance baselines]]
    @Test func scaling() async throws {
        let server = try await ExtensionHTTPFixture.start()
        defer { server.listener.cancel() }
        let address = "http://127.0.0.1:\(server.port)/"
        let ready = "document.readyState === 'complete' && window.blockedScriptRan === true"
        var samples: [ScalingSample] = []
        for count in [10, 100] {
            let browser = try BenchmarkWindow(count: count, address: address)
            defer { browser.close() }
            let first = browser.tabs[0]
            try await browser.waitForFixture(first, expression: ready)
            let host = try #require(browser.views(MountedTabHost.self).first)
            let initiallyLive = browser.liveCount
            #expect(initiallyLive == 1)

            // Mount each selected tab in order, then wait for the fixture
            // loads together. Network completion is outside the timed work.
            for tab in browser.tabs.dropFirst() {
                browser.store.select(tab.id)
                browser.layout()
                try #require(host.selectedID == tab.id)
            }
            for tab in browser.tabs.dropFirst() {
                try await browser.waitForFixture(tab, expression: ready)
            }
            let visitedLive = browser.liveCount
            #expect(visitedLive == count)
            #expect(host.mounted.count == count)

            browser.store.newTab(address: address, inBackground: true)
            let background = try #require(browser.store.session.workspaces[0].tabs.last)
            try await browser.waitForFixture(background, expression: ready)
            let backgroundLive = browser.liveCount
            #expect(backgroundLive == count + 1)
            #expect(host.mounted[background.id] == nil)
            browser.store.closeTab(background.id)
            #expect(browser.store.existingController(for: background.focusedPane) == nil)

            _ = try #require(browser.views(PaneShadowView.self).first)
            let scroll = try #require(browser.views(NSScrollView.self).first { view in
                view.bounds.width <= browser.store.sidebarWidth && (view.documentView?.frame.height ?? 0) > view.bounds.height
            })
            let clip = scroll.contentView
            let scrollRange = try #require(scroll.documentView).frame.height - clip.bounds.height
            #expect(scrollRange > 0)

            browser.store.select(first.id)
            browser.flush()
            var workloads: [String: Workload] = [:]
            func targetTab(_ step: Int) -> UUID { browser.tabs[1 + step % 2].id }
            workloads["select"] = try browser.measure("Tab selection", operation: { step in
                browser.store.select(targetTab(step))
            }, verify: { step in
                host.selectedID == targetTab(step)
            })
            let selected = browser.store.session.selectedTab
            func title(_ step: Int) -> String { "Benchmark edit \(step)" }
            workloads["edit_title"] = try browser.measure("Unrelated tab title", operation: { step in
                browser.store.editTab(first.id) { $0.title = title(step) }
            }, verify: { step in
                browser.store.session.workspaces[0].tabs[0].title == title(step)
            })
            #expect(browser.store.session.selectedTab == selected)
            func width(_ step: Int) -> CGFloat { step.isMultiple(of: 2) ? 1000 : 1100 }
            workloads["resize"] = try browser.measure("Window resize", operation: { step in
                browser.window.setContentSize(NSSize(width: width(step), height: 390))
            }, verify: { step in
                browser.window.contentView?.frame.width == width(step)
            })
            func scrollY(_ step: Int) -> CGFloat { scrollRange * CGFloat(1 + step % 4) / 4 }
            workloads["scroll"] = try browser.measure("Sidebar scroll", operation: { step in
                clip.scroll(to: NSPoint(x: clip.bounds.minX, y: scrollY(step)))
                scroll.reflectScrolledClipView(clip)
            }, verify: { step in
                abs(clip.bounds.minY - scrollY(step)) <= 1
            })
            samples.append(ScalingSample(tabs: count, initiallyLive: initiallyLive, visitedLive: visitedLive,
                backgroundLive: backgroundLive, workloads: workloads))
        }

        try report("BEND_TAB_SCALING", ScalingReport(samples: samples))
    }

    // @lat: [[lat.md/tests/session-tests#Tab memory footprint]]
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BEND_TAB_MEMORY_COUNT"] != nil))
    func footprint() async throws {
        let env = ProcessInfo.processInfo.environment
        let count = try #require(env["BEND_TAB_MEMORY_COUNT"].flatMap(Int.init))
        let address = try #require(env["BEND_TAB_MEMORY_URL"])
        try #require(count > 0)
        let browser = try BenchmarkWindow(count: count, address: address)
        defer { browser.close() }
        let before = try CPUTime()
        let start = ContinuousClock.now
        for tab in browser.tabs {
            if tab.id != browser.store.session.selectedTab { browser.store.select(tab.id) }
            try await browser.waitForFixture(tab, expression: "window.bendMemoryReady === true")
        }
        let after = try CPUTime()
        let seconds = start.duration(to: .now).components
        try await Task.sleep(for: .seconds(1))
        let selected = try #require(browser.store.existingController(for: browser.store.selectedTab.focusedPane))
        _ = try #require(try webContentPID(selected.webView), "Selected fixture has no live WebContent process")
        // Do not run JavaScript on hidden tabs at sampling time; that would
        // disturb the idle pages or defeat future controller eviction.
        let liveViews = browser.tabs.compactMap { browser.store.existingController(for: $0.focusedPane)?.webView }
        let attachedPIDs = try liveViews.compactMap(webContentPID)
        let host = try ProcessFootprint(pid: getpid())
        let webContent = try Set(attachedPIDs).sorted().map(ProcessFootprint.init)
        let webBytes = webContent.reduce(0) { $0 + $1.physicalFootprintBytes }
        try report("BEND_TAB_MEMORY", FootprintSample(tabs: count, liveControllers: liveViews.count,
            tabsWithWebContent: attachedPIDs.count, host: host, webContent: webContent, webContentProcessCount: webContent.count, webContentFootprintBytes: webBytes,
            totalFootprintBytes: host.physicalFootprintBytes + webBytes,
            loadMainThreadMilliseconds: Double(after.main - before.main) / 1e6,
            loadWallMilliseconds: Double(seconds.seconds) * 1000 + Double(seconds.attoseconds) / 1e15))
    }

}

@MainActor
private final class BenchmarkWindow {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendTabBench-\(UUID())")
    let store: BrowserStore
    let tabs: [BrowserTab]
    let window: BrowseWindow

    init(count: Int, address: String) throws {
        _ = NSApplication.shared
        tabs = (0..<count).map { BrowserTab(title: "Benchmark tab \($0 + 1)", pages: [Page(address: address)]) }
        let sessionFile = root.appendingPathComponent("session.json")
        var session = BrowserSession()
        session.workspaces = [Workspace(name: "Benchmark", tabs: tabs)]
        session.selectedTab = tabs[0].id
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            try JSONEncoder().encode(session).write(to: sessionFile)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        let manager = ExtensionManager(root: root.appendingPathComponent("extensions"), persistent: false,
            websiteDataStore: .nonPersistent(), notifications: TestNotifications())
        manager.presentsWindows = false
        store = BrowserStore(sessionFile: sessionFile, extensionManager: manager)
        window = BrowseWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 390),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.browserStore = store
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.toolbar = NSToolbar(identifier: "TabPerformance")
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: BrowserView(store: store).ignoresSafeArea()
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            })
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFront(nil)
    }

    var liveCount: Int {
        store.session.workspaces.flatMap(\.tabs).flatMap(\.pages)
            .count { store.existingController(for: $0.id) != nil }
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        store.stopWindow()
        try? FileManager.default.removeItem(at: root)
    }

    func views<T: NSView>(_ type: T.Type) -> [T] {
        func walk(_ view: NSView) -> [T] {
            if let match = view as? T { return [match] }
            return view.subviews.flatMap(walk)
        }
        return window.contentView.map(walk) ?? []
    }

    func layout() {
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func flush() {
        layout()
        window.displayIfNeeded()
    }

    func waitForFixture(_ tab: BrowserTab, expression: String) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            layout()
            if let web = store.existingController(for: tab.focusedPane)?.webView, !web.isLoading,
               (try? await web.evaluateJavaScript(expression)) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw BenchmarkError.fixtureTimeout(tab.title)
    }

    func measure(_ name: StaticString, operation: (Int) -> Void, verify: (Int) -> Bool) throws -> Workload {
        let counters = TabPerformanceCounters(store: store, window: window)
        TabPerformanceCounters.active = counters
        defer { TabPerformanceCounters.active = nil }
        let signposter = OSSignposter(subsystem: "com.bend.browser", category: "TabPerformance")
        let interval = signposter.beginInterval(name)
        defer { signposter.endInterval(name, interval) }
        let before = try CPUTime()
        let start = ContinuousClock.now
        for step in 0..<Workload.steps {
            operation(step)
            flush()
            guard verify(step) else { throw BenchmarkError.workloadDidNotApply(String(describing: name), step) }
        }
        let elapsed = start.duration(to: .now).components
        let after = try CPUTime()
        return Workload(wallMilliseconds: Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15,
            mainThreadMilliseconds: Double(after.main - before.main) / 1e6,
            liveThreadsMilliseconds: Double(after.live - before.live) / 1000, counts: counters.counts)
    }
}

private enum BenchmarkError: Error {
    case fixtureTimeout(String)
    case cpuSampling(kern_return_t)
    case workloadDidNotApply(String, Int)
}

private struct CPUTime {
    let main: UInt64
    let live: Int64

    init() throws {
        main = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        var times = task_thread_times_info_data_t()
        let capacity = MemoryLayout<task_thread_times_info_data_t>.size / MemoryLayout<integer_t>.size
        var count = mach_msg_type_number_t(capacity)
        let result = withUnsafeMutablePointer(to: &times) {
            $0.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw BenchmarkError.cpuSampling(result) }
        live = (Int64(times.user_time.seconds) + Int64(times.system_time.seconds)) * 1_000_000
            + Int64(times.user_time.microseconds) + Int64(times.system_time.microseconds)
    }
}

@MainActor
private func webContentPID(_ web: WKWebView) throws -> pid_t? {
    // WebKit XPC services may be parented by launchd. Ask each fixture view
    // which process serves its main frame so unrelated WebKit apps are excluded.
    let selector = NSSelectorFromString("_webProcessIdentifier")
    try #require(web.responds(to: selector), "This WebKit build does not expose fixture process IDs")
    let implementation = try #require(web.method(for: selector))
    typealias Getter = @convention(c) (AnyObject, Selector) -> pid_t
    let pid = unsafeBitCast(implementation, to: Getter.self)(web, selector)
    return pid > 0 ? pid : nil
}

private struct ProcessFootprint: Encodable {
    let pid: pid_t
    let physicalFootprintBytes: UInt64

    init(pid: pid_t) throws {
        self.pid = pid
        var usage = rusage_info_v0()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V0, $0)
            }
        }
        try #require(result == 0 && usage.ri_phys_footprint > 0, "Cannot read physical footprint for PID \(pid)")
        physicalFootprintBytes = usage.ri_phys_footprint
    }
}

private struct FootprintSample: Encodable {
    let tabs: Int
    let liveControllers: Int
    let tabsWithWebContent: Int
    let host: ProcessFootprint
    let webContent: [ProcessFootprint]
    let webContentProcessCount: Int
    let webContentFootprintBytes: UInt64
    let totalFootprintBytes: UInt64
    let loadMainThreadMilliseconds: Double
    let loadWallMilliseconds: Double
}

private struct Workload: Encodable {
    static let steps = 8
    let wallMilliseconds: Double
    let mainThreadMilliseconds: Double
    let liveThreadsMilliseconds: Double
    let counts: TabPerformanceCounters.Counts
}

private struct ScalingSample: Encodable {
    let tabs: Int
    let initiallyLive: Int
    let visitedLive: Int
    let backgroundLive: Int
    let workloads: [String: Workload]
}

private struct ScalingReport: Encodable {
    let schemaVersion = 1
    let stepsPerWorkload = Workload.steps
    let samples: [ScalingSample]
    let ratios100Over10: [String: [String: Double]]

    init(samples: [ScalingSample]) {
        self.samples = samples
        ratios100Over10 = Dictionary(uniqueKeysWithValues: samples[1].workloads.map { name, large in
            let small = samples[0].workloads[name]!
            func ratio(_ numerator: Double, _ denominator: Double) -> Double? {
                denominator > 0 && numerator >= 0 ? numerator / denominator : nil
            }
            return (name, [
                "wall": ratio(large.wallMilliseconds, small.wallMilliseconds),
                "mainThreadCPU": ratio(large.mainThreadMilliseconds, small.mainThreadMilliseconds),
                "liveThreadsCPU": ratio(large.liveThreadsMilliseconds, small.liveThreadsMilliseconds),
            ].compactMapValues { $0 })
        })
    }
}

private func report(_ marker: String, _ value: some Encodable) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    print("\(marker) \(String(decoding: try encoder.encode(value), as: UTF8.self))")
}
#endif
