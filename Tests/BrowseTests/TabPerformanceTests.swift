#if DEBUG
import AppKit
import BrowseCore
import Combine
import Darwin
import os
import QuartzCore
import SwiftUI
import Testing
import WebKit
@testable import Browse

@Suite(.serialized)
@MainActor
struct TabPerformanceTests {
    // @lat: [[lat.md/tests/session-tests#Tab performance baselines]]
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BEND_RUN_TAB_SCALING"] == "1"))
    func scaling() async throws {
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

            // Let each fixture finish while selected. On hosted runners,
            // WebKit can defer loads when many new views are hidden at once.
            for tab in browser.tabs.dropFirst() {
                browser.store.select(tab.id)
                try await browser.waitForFixture(tab, expression: ready)
                try #require(host.selectedID == tab.id)
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
        let before = CPUTime()
        let start = ContinuousClock.now
        for tab in browser.tabs {
            if tab.id != browser.store.session.selectedTab { browser.store.select(tab.id) }
            try await browser.waitForFixture(tab, expression: "window.bendMemoryReady === true")
        }
        let after = CPUTime()
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

    // @lat: [[lat.md/tests/session-tests#Tab speed benchmarks]]
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BEND_RUN_TAB_SPEED"] == "1"
        || ProcessInfo.processInfo.environment["BEND_SPEED_OUT"] != nil))
    func speed() async throws {
        // 1. Location popup typing at (10 tabs, 300 history) -> (100 tabs, 3,000 history).
        var typingSamples: [SpeedUISample] = []
        for (tabs, historyCount) in [(10, 300), (100, 3000)] {
            let browser = try BenchmarkWindow(count: tabs, address: "bend://start",
                size: NSSize(width: 1200, height: 800), origin: NSPoint(x: -20_000, y: -20_000), makeKey: true)
            defer { browser.close() }
            seedHistory(browser.store, pages: historyCount)
            let panel = AddressPanelController(store: browser.store, parentWindow: browser.window)
            browser.settle()
            panel.show(for: browser.store.selectedTab.focusedPane)
            defer { panel.dismiss(restoreFocus: false) }
            browser.settle()

            let popup = try #require(browser.window.childWindows?.first)
            let content = try #require(popup.contentView)
            let field = try #require(descendants(NSTextField.self, in: content).first { $0.isEditable })
            let editor = field.currentEditor() as? NSTextView
            let words = Array("github pull requests")

            typingSamples.append(measureUI([browser], tabs: tabs, history: historyCount, steps: words.count) { i in
                let text = String(words[0...i])
                field.stringValue = text
                editor?.string = text
                panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            })
            try? await Task.sleep(for: .milliseconds(50))
        }

        // 2. Find in Page typing on a loaded local fixture at 10 -> 100 tabs.
        var findingSamples: [SpeedUISample] = []
        do {
            let server = try await ExtensionHTTPFixture.start()
            defer { server.listener.cancel() }
            let address = "http://127.0.0.1:\(server.port)/"
            for tabs in [10, 100] {
                let browser = try BenchmarkWindow(count: tabs, address: "https://example.invalid/",
                    selectedAddress: address, size: NSSize(width: 1200, height: 800),
                    origin: NSPoint(x: -20_000, y: -20_000), makeKey: true)
                defer { browser.close() }
                browser.settle()

                let first = browser.tabs[0]
                try await browser.waitForFixture(first, expression: "document.readyState === 'complete' && window.blockedScriptRan === true")
                let controller = try #require(browser.store.existingController(for: first.focusedPane))
                _ = try await controller.webView.evaluateJavaScript(
                    "document.body.innerHTML = '<p>github pull requests review queue</p><p>github issues and pull requests</p><p>documentation search index</p>'; true"
                )
                browser.settle()

                let surface = try #require(browser.views(WebSurfaceHost.self).first)
                surface.performFindAction(.showFindInterface)
                browser.settle()

                let bar = try #require(surface.findBarView)
                let field = try #require(descendants(NSTextField.self, in: bar).first { $0.isEditable })
                field.selectText(nil)
                let editor = field.currentEditor() as? NSTextView
                let words = Array("github pull requests")

                var finalKeyStart = 0.0
                var sample = measureUI([browser], tabs: tabs, steps: words.count) { i in
                    if i == words.count - 1 { finalKeyStart = CACurrentMediaTime() }
                    let text = String(words[0...i])
                    field.stringValue = text
                    editor?.string = text
                    surface.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
                }
                // The fixture contains exactly one occurrence of the complete query.
                while surface.matchCount != 1 {
                    try #require(CACurrentMediaTime() - finalKeyStart < 5, "Final find result timed out")
                    try await Task.sleep(for: .milliseconds(1))
                }
                sample.finalKeyToResultMs = (CACurrentMediaTime() - finalKeyStart) * 1000
                findingSamples.append(sample)
            }
        }

        // 3. Changing an @Published store property that no sidebar row or pane reads at 10 -> 100 tabs.
        var unrelatedSamples: [SpeedUISample] = []
        for tabs in [10, 100] {
            let browser = try BenchmarkWindow(count: tabs, address: "bend://start",
                size: NSSize(width: 1200, height: 800), origin: NSPoint(x: -20_000, y: -20_000))
            defer { browser.close() }
            browser.settle()
            #expect(browser.store.sidebarVisible)

            unrelatedSamples.append(measureUI([browser], tabs: tabs, steps: 60) { i in
                browser.store.sidebarFloating = i.isMultiple(of: 2)
            })
            browser.store.sidebarFloating = false
            try? await Task.sleep(for: .milliseconds(50))
        }

        // 4. Frame-paced sidebar resize drag across two shared-store windows at 10 -> 100 tabs.
        var dragSamples: [SpeedDragSample] = []
        for tabs in [10, 100] {
            let primary = try BenchmarkWindow(count: tabs, address: "bend://start",
                size: NSSize(width: 1200, height: 800), origin: NSPoint(x: -20_000, y: -20_000))
            defer { primary.close() }
            let secondary = try BenchmarkWindow(count: tabs, address: "bend://start",
                size: NSSize(width: 1200, height: 800), origin: NSPoint(x: -20_000, y: -19_000),
                sharedStore: primary.store)
            defer { secondary.close() }
            primary.settle()
            secondary.settle()

            let handle = try #require(primary.views(SidebarResizeView.self).first)
            let grab = handle.convert(NSPoint(x: 3, y: handle.bounds.midY), to: nil)

            var published = 0
            let watchPrimary = primary.store.objectWillChange.sink { _ in published += 1 }
            let watchSecondary = secondary.store.objectWillChange.sink { _ in published += 1 }
            defer {
                watchPrimary.cancel()
                watchSecondary.cancel()
            }

            let counters = TabPerformanceCounters(stores: [primary.store, secondary.store],
                windows: [primary.window, secondary.window])
            TabPerformanceCounters.active = counters
            defer { TabPerformanceCounters.active = nil }

            let clock = LoopClock()
            clock.start()
            defer { clock.stop() }

            let steps = 60
            try sendMouse(.leftMouseDown, at: grab, to: primary.window)
            try await Task.sleep(for: .milliseconds(16))
            for step in 1...steps {
                let out = CGFloat(step <= steps / 2 ? step : steps - step) * 2
                clock.mark()
                try sendMouse(.leftMouseDragged, at: NSPoint(x: grab.x + out + 2, y: grab.y), to: primary.window)
                try await Task.sleep(for: .milliseconds(16))
                if step == steps / 2 {
                    let current = handle.convert(NSPoint(x: 3, y: handle.bounds.midY), to: nil)
                    try #require(abs(current.x - grab.x) > 30, "Sidebar edge did not follow the drag")
                }
            }
            let publishedHeld = published
            try sendMouse(.leftMouseUp, at: NSPoint(x: grab.x + 2, y: grab.y), to: primary.window)
            primary.settle()
            secondary.settle()
            try #require(!clock.marked.isEmpty, "No drag frames were sampled")

            dragSamples.append(SpeedDragSample(
                tabs: tabs,
                windows: 2,
                stepMs: LoopClock.summary(clock.marked),
                otherMs: LoopClock.summary(clock.unmarked),
                publishedWhileHeld: publishedHeld,
                rowsPerStep: Double(counters.counts.sidebarRowBodies) / Double(steps),
                paneBodiesPerStep: Double(counters.counts.browserPaneBodies) / Double(steps),
                mountedRootReplacementsPerStep: Double(counters.counts.mountedRootReplacements) / Double(steps),
                shadowInvalidationsPerStep: Double(counters.counts.shadowInvalidations) / Double(steps),
                shadowDrawsPerStep: Double(counters.counts.shadowDraws) / Double(steps)
            ))
            try? await Task.sleep(for: .milliseconds(50))
        }

        // 5. Pure history suggestion ranking across 300 -> 3,000 entries.
        var rankingSamples: [SpeedMicroSample] = []
        let queries = [
            "g", "gi", "git", "gith", "githu", "github", "github p", "github pu", "github pul", "github pull",
            "zq", "zqx", "zqxw", "issu", "issue", "issues", "isuses", "documnet", "docum", "documen"
        ]
        for entryCount in [300, 3000] {
            var history = BrowsingHistory()
            let words = ["github", "issues", "pull", "requests", "docs", "document", "search", "mail", "news", "maps"]
            for i in 0..<entryCount {
                history.record(
                    url: "https://site\(i).example/page",
                    title: "\(words[i % words.count]) \(words[(i / 10) % words.count]) page \(i)"
                )
            }
            var times: [Double] = []
            for _ in 0..<5 {
                for query in queries {
                    let start = CACurrentMediaTime()
                    _ = history.suggestions(for: query, limit: 6)
                    times.append((CACurrentMediaTime() - start) * 1000)
                }
            }
            rankingSamples.append(SpeedMicroSample(count: entryCount, ms: percentile(times, 0.5)))
        }

        // 6. Cold-loading a BrowserStore from a persisted session file at 10 -> 100 tabs.
        var sessionSamples: [SpeedMicroSample] = []
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendSessionBench-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            for tabCount in [10, 100] {
                let sessionFile = root.appendingPathComponent("session-\(tabCount).json")
                let tabs = (0..<tabCount).map { BrowserTab(title: "Saved tab \($0 + 1)", pages: [Page(address: "https://tab\($0).example/")]) }
                var session = BrowserSession()
                session.workspaces = [Workspace(name: "Saved", tabs: tabs)]
                session.selectedTab = tabs[0].id
                try JSONEncoder().encode(session).write(to: sessionFile)

                var times: [Double] = []
                var openedStores: [BrowserStore] = []
                defer { for store in openedStores { store.stopWindow() } }
                for _ in 0..<5 {
                    let manager = ExtensionManager(
                        root: root.appendingPathComponent("extensions-\(UUID())"),
                        persistent: false,
                        websiteDataStore: .nonPersistent(),
                        notifications: TestNotifications()
                    )
                    manager.presentsWindows = false
                    let start = CACurrentMediaTime()
                    let opened = BrowserStore(sessionFile: sessionFile, persistentExtensions: false, extensionManager: manager)
                    times.append((CACurrentMediaTime() - start) * 1000)
                    openedStores.append(opened)
                }
                sessionSamples.append(SpeedMicroSample(count: tabCount, ms: percentile(times, 0.5)))
            }
        }

        let speedReport = SpeedReport(
            ui: [
                "typing": SpeedPair.ui(low: typingSamples[0], high: typingSamples[1]),
                "finding": SpeedPair.ui(low: findingSamples[0], high: findingSamples[1]),
                "unrelatedChange": SpeedPair.ui(low: unrelatedSamples[0], high: unrelatedSamples[1]),
            ],
            sidebarEdge: SpeedPair.drag(low: dragSamples[0], high: dragSamples[1]),
            micro: [
                "ranking": SpeedPair.micro(low: rankingSamples[0], high: rankingSamples[1]),
                "sessionOpen": SpeedPair.micro(low: sessionSamples[0], high: sessionSamples[1]),
            ]
        )

        try report("BEND_TAB_SPEED", speedReport)
        if let out = ProcessInfo.processInfo.environment["BEND_SPEED_OUT"] {
            let url = URL(fileURLWithPath: out)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(speedReport).write(to: url)
        }
    }

    private func measureUI(_ browsers: [BenchmarkWindow], tabs: Int, history: Int? = nil, steps: Int, _ step: (Int) -> Void) -> SpeedUISample {
        var sends = 0
        let watches = browsers.map { $0.store.objectWillChange.sink { _ in sends += 1 } }
        defer { for watch in watches { watch.cancel() } }

        let counters = TabPerformanceCounters(stores: browsers.map(\.store), windows: browsers.map(\.window))
        TabPerformanceCounters.active = counters
        defer { TabPerformanceCounters.active = nil }

        var times: [Double] = []
        for i in 0..<steps {
            let start = CACurrentMediaTime()
            step(i)
            for browser in browsers { browser.drain() }
            times.append((CACurrentMediaTime() - start) * 1000)
        }

        let counts = counters.counts
        return SpeedUISample(
            tabs: tabs,
            history: history,
            ms: percentile(times, 0.5),
            p95Ms: percentile(times, 0.95),
            totalMs: times.reduce(0, +),
            storeChangesPerStep: Double(sends) / Double(steps),
            rowsPerStep: Double(counts.sidebarRowBodies) / Double(steps),
            paneBodiesPerStep: Double(counts.browserPaneBodies) / Double(steps),
            mountedRootReplacementsPerStep: Double(counts.mountedRootReplacements) / Double(steps),
            shadowInvalidationsPerStep: Double(counts.shadowInvalidations) / Double(steps),
            shadowDrawsPerStep: Double(counts.shadowDraws) / Double(steps)
        )
    }

    private func seedHistory(_ store: BrowserStore, pages: Int) {
        let words = ["github", "issues", "pull", "requests", "docs", "document", "search", "mail", "news", "maps"]
        for i in 0..<pages {
            store.recordVisit(
                url: "https://site\(i).example/page",
                title: "\(words[i % words.count]) \(words[(i / 10) % words.count]) page \(i)"
            )
        }
    }

    private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants(type, in: $0) }
    }

    private func sendMouse(_ type: NSEvent.EventType, at point: NSPoint, to window: NSWindow) throws {
        let event = try #require(NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        ))
        window.sendEvent(event)
    }
}

@MainActor
private final class BenchmarkWindow {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendTabBench-\(UUID())")
    let store: BrowserStore
    let tabs: [BrowserTab]
    let window: BrowseWindow

    init(
        count: Int,
        address: String,
        selectedAddress: String? = nil,
        size: NSSize = NSSize(width: 1100, height: 390),
        origin: NSPoint = NSPoint(x: -10000, y: -10000),
        makeKey: Bool = false,
        sharedStore: BrowserStore? = nil
    ) throws {
        _ = NSApplication.shared
        tabs = (0..<count).map { index in
            let tabAddress = index == 0 ? (selectedAddress ?? address) : address
            return BrowserTab(title: "Benchmark tab \(index + 1)", pages: [Page(address: tabAddress)])
        }
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
        store = BrowserStore(sessionFile: sessionFile, persistentExtensions: false,
            extensionManager: manager, sharedStore: sharedStore)
        window = BrowseWindow(contentRect: NSRect(origin: origin, size: size),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.browserStore = store
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.toolbar = NSToolbar(identifier: "TabPerformance-\(UUID())")
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: BrowserView(store: store).ignoresSafeArea()
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            })
        window.setFrameOrigin(origin)
        if makeKey {
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }
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

    func drain() {
        RunLoop.current.run(mode: .default, before: Date())
        flush()
        for child in window.childWindows ?? [] {
            child.contentView?.layoutSubtreeIfNeeded()
            child.displayIfNeeded()
        }
    }

    func settle() {
        for _ in 0..<10 { drain() }
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
        var storeChanges = 0
        let watch = store.objectWillChange.sink { _ in storeChanges += 1 }
        defer { watch.cancel() }
        let counters = TabPerformanceCounters(store: store, window: window)
        TabPerformanceCounters.active = counters
        defer { TabPerformanceCounters.active = nil }
        let signposter = OSSignposter(subsystem: "com.bend.browser", category: "TabPerformance")
        let interval = signposter.beginInterval(name)
        defer { signposter.endInterval(name, interval) }
        let before = CPUTime()
        let start = ContinuousClock.now
        var stepTimes: [Double] = []
        for step in 0..<Workload.steps {
            let stepStart = CACurrentMediaTime()
            operation(step)
            flush()
            guard verify(step) else { throw BenchmarkError.workloadDidNotApply(String(describing: name), step) }
            stepTimes.append((CACurrentMediaTime() - stepStart) * 1000)
        }
        let elapsed = start.duration(to: .now).components
        let after = CPUTime()
        return Workload(wallMilliseconds: Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15,
            mainThreadMilliseconds: Double(after.main - before.main) / 1e6,
            processMilliseconds: Double(after.process - before.process) / 1e6,
            medianStepMilliseconds: percentile(stepTimes, 0.5),
            p95StepMilliseconds: percentile(stepTimes, 0.95),
            storeChanges: storeChanges,
            counts: counters.counts)
    }
}

private func percentile(_ values: [Double], _ quantile: Double) -> Double {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return 0 }
    return sorted[min(sorted.count - 1, Int(quantile * Double(sorted.count)))]
}

/// Times main run-loop turns from wake (`afterWaiting`) to sleep (`beforeWaiting`),
/// separating turns marked by the benchmark from unrelated background turns.
private final class LoopClock: @unchecked Sendable {
    struct Summary: Encodable {
        let count: Int
        let p50: Double
        let p95: Double
        let max: Double
        let total: Double
    }

    private(set) var marked: [Double] = []
    private(set) var unmarked: [Double] = []
    private var woke: CFAbsoluteTime = 0
    private var carrying = false
    private var observers: [CFRunLoopObserver] = []

    func mark() { carrying = true }

    func start() {
        let wake = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min) { [unowned self] _, _ in
            woke = CFAbsoluteTimeGetCurrent()
        }
        let sleep = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { [unowned self] _, _ in
            guard woke > 0 else { return }
            let ms = (CFAbsoluteTimeGetCurrent() - woke) * 1000
            if carrying { marked.append(ms) } else { unmarked.append(ms) }
            carrying = false
            woke = 0
        }
        for observer in [wake, sleep].compactMap({ $0 }) {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            observers.append(observer)
        }
    }

    func stop() {
        for observer in observers { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observers = []
    }

    static func summary(_ values: [Double]) -> Summary {
        guard !values.isEmpty else { return Summary(count: 0, p50: 0, p95: 0, max: 0, total: 0) }
        let sorted = values.sorted()
        func at(_ q: Double) -> Double { sorted[min(sorted.count - 1, Int(q * Double(sorted.count)))] }
        return Summary(
            count: sorted.count,
            p50: at(0.5),
            p95: at(0.95),
            max: sorted.last!,
            total: sorted.reduce(0, +)
        )
    }
}

private enum BenchmarkError: Error {
    case fixtureTimeout(String)
    case workloadDidNotApply(String, Int)
}

private struct CPUTime {
    let main = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    let process = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
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

private struct SpeedUISample: Encodable {
    let tabs: Int
    let history: Int?
    var finalKeyToResultMs: Double? = nil
    let ms: Double
    let p95Ms: Double
    let totalMs: Double
    let storeChangesPerStep: Double
    let rowsPerStep: Double
    let paneBodiesPerStep: Double
    let mountedRootReplacementsPerStep: Double
    let shadowInvalidationsPerStep: Double
    let shadowDrawsPerStep: Double
}

private struct SpeedDragSample: Encodable {
    let tabs: Int
    let windows: Int
    let stepMs: LoopClock.Summary
    let otherMs: LoopClock.Summary
    let publishedWhileHeld: Int
    let rowsPerStep: Double
    let paneBodiesPerStep: Double
    let mountedRootReplacementsPerStep: Double
    let shadowInvalidationsPerStep: Double
    let shadowDrawsPerStep: Double
}

private struct SpeedMicroSample: Encodable {
    let count: Int
    let ms: Double
}

private struct SpeedPair<Sample: Encodable>: Encodable {
    let low: Sample
    let high: Sample
    let ratio: [String: Double]
}

private func ratioIfValid(_ numerator: Double, _ denominator: Double) -> Double? {
    denominator > 0 && numerator >= 0 ? numerator / denominator : nil
}

private extension SpeedPair where Sample == SpeedUISample {
    static func ui(low: SpeedUISample, high: SpeedUISample) -> Self {
        SpeedPair(low: low, high: high, ratio: [
            "ms": ratioIfValid(high.ms, low.ms),
            "p95Ms": ratioIfValid(high.p95Ms, low.p95Ms),
            "totalMs": ratioIfValid(high.totalMs, low.totalMs),
        ].compactMapValues { $0 })
    }
}

private extension SpeedPair where Sample == SpeedDragSample {
    static func drag(low: SpeedDragSample, high: SpeedDragSample) -> Self {
        SpeedPair(low: low, high: high, ratio: [
            "stepP50": ratioIfValid(high.stepMs.p50, low.stepMs.p50),
            "stepP95": ratioIfValid(high.stepMs.p95, low.stepMs.p95),
            "stepMax": ratioIfValid(high.stepMs.max, low.stepMs.max),
        ].compactMapValues { $0 })
    }
}

private extension SpeedPair where Sample == SpeedMicroSample {
    static func micro(low: SpeedMicroSample, high: SpeedMicroSample) -> Self {
        SpeedPair(low: low, high: high, ratio: [
            "ms": ratioIfValid(high.ms, low.ms),
        ].compactMapValues { $0 })
    }
}

private struct SpeedReport: Encodable {
    let schemaVersion = 3
    let ui: [String: SpeedPair<SpeedUISample>]
    let sidebarEdge: SpeedPair<SpeedDragSample>
    let micro: [String: SpeedPair<SpeedMicroSample>]
}

private struct Workload: Encodable {
    static let steps = 8
    let wallMilliseconds: Double
    let mainThreadMilliseconds: Double
    let processMilliseconds: Double
    let medianStepMilliseconds: Double
    let p95StepMilliseconds: Double
    let storeChanges: Int
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
    let schemaVersion = 2
    let stepsPerWorkload = Workload.steps
    let samples: [ScalingSample]
    let ratios100Over10: [String: [String: Double]]

    init(samples: [ScalingSample]) {
        self.samples = samples
        ratios100Over10 = Dictionary(uniqueKeysWithValues: samples[1].workloads.map { name, large in
            let small = samples[0].workloads[name]!
            return (name, [
                "wall": ratioIfValid(large.wallMilliseconds, small.wallMilliseconds),
                "mainThreadCPU": ratioIfValid(large.mainThreadMilliseconds, small.mainThreadMilliseconds),
                "processCPU": ratioIfValid(large.processMilliseconds, small.processMilliseconds),
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
