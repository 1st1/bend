import Foundation
import AppKit
import WebKit
import SwiftUI
import Testing
@testable import Browse

// @lat: [[tests#Input logging preference]]
@Test @MainActor func inputTracePreference() throws {
    let suite = "BrowseTracePreference-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    InputDiagnostics.stop()
    defer {
        InputDiagnostics.stop()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
    let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
        modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil,
        eventNumber: 1, clickCount: 1, pressure: 1))
    func record() {
        InputDiagnostics.record(.application, event: event)
        InputDiagnostics.transition(.paneMove, .finished, paneID: UUID())
        InputDiagnostics.flush()
    }
    InputDiagnostics.applyPreferences(defaults: defaults, root: root)
    record()
    #expect(!FileManager.default.fileExists(atPath: root.path))

    defaults.set(true, forKey: InputDiagnostics.enabledPreferenceKey)
    InputDiagnostics.applyPreferences(defaults: defaults, root: root)
    record()
    #expect(try traceRows(root, "events").count == 1)
    #expect(try traceRows(root, "panes").count == 1)

    // A new preferences instance restores logging before the session is loaded.
    InputDiagnostics.stop()
    let restored = try #require(UserDefaults(suiteName: suite))
    InputDiagnostics.applyPreferences(defaults: restored, root: root)
    record()
    #expect(try traceRows(root, "events").count == 2)
    #expect(try traceRows(root, "panes").count == 2)

    defaults.set(false, forKey: InputDiagnostics.enabledPreferenceKey)
    InputDiagnostics.applyPreferences(defaults: defaults, root: root)
    record()
    #expect(try traceRows(root, "events").count == 2)
    #expect(try traceRows(root, "panes").count == 2)
    InputDiagnostics.applyPreferences(defaults: restored, root: root)
    record()
    #expect(try traceRows(root, "events").count == 2)
    #expect(try traceRows(root, "panes").count == 2)
}

// @lat: [[tests#Input trace rotation]]
@Test func inputTraceRotation() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseInputTest-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("events.jsonl")
    let previous = root.appendingPathComponent("events.previous.jsonl")
    let first = InputTraceFile(root: root, maximumBytes: 16)
    #expect(first.enqueue(Data("1111111\n".utf8)))
    #expect(first.enqueue(Data("2222222\n".utf8)))
    first.flush()
    #expect(try String(contentsOf: file, encoding: .utf8) == "1111111\n2222222\n")

    // A fresh writer appends to the same bounded history, as on app relaunch.
    let second = InputTraceFile(root: root, maximumBytes: 16)
    for line in ["3333333\n", "4444444\n", "5555555\n"] {
        #expect(second.enqueue(Data(line.utf8)))
    }
    second.flush()
    #expect(try String(contentsOf: previous, encoding: .utf8) == "3333333\n4444444\n")
    #expect(try String(contentsOf: file, encoding: .utf8) == "5555555\n")
    #expect(!second.enqueue(Data(repeating: 65, count: 17)))
    second.flush()
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 2)
    for url in [file, previous] {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(((attributes[.size] as? NSNumber)?.intValue ?? 17) <= 16)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}

// @lat: [[tests#Independent input and pane log retention]]
@Test func inputTraceStreams() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseTraceStreams-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let events = InputTraceFile(root: root, maximumBytes: 16)
    let panes = InputTraceFile(root: root, stream: .panes, maximumBytes: 16)
    #expect(panes.enqueue(Data("pane\n".utf8)))
    for _ in 0..<20 { #expect(events.enqueue(Data("event\n".utf8))) }
    events.flush(); panes.flush()
    #expect(try String(contentsOf: root.appendingPathComponent("panes.jsonl"), encoding: .utf8) == "pane\n")
    // Simulate upgrading from a build with larger rotation limits.
    for name in ["panes.jsonl", "panes.previous.jsonl"] {
        try Data(repeating: 65, count: 32).write(to: root.appendingPathComponent(name))
    }
    let reopened = InputTraceFile(root: root, stream: .panes, maximumBytes: 16)
    #expect(reopened.enqueue(Data("new\n".utf8)))
    reopened.flush()
    #expect(try String(contentsOf: root.appendingPathComponent("panes.jsonl"), encoding: .utf8) == "new\n")
    for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
        #expect(try Data(contentsOf: url).count <= 16)
    }
    #expect(InputTraceFile(root: root).maximumBytes == 500 * 1024)
}

// @lat: [[tests#Pane trace correlation]]
@Test @MainActor func inputTracePaneCorrelation() throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseTracePanes-\(UUID())")
    InputDiagnostics.start(root: root)
    defer { InputDiagnostics.stop(); try? FileManager.default.removeItem(at: root) }
    let window = BrowseWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    window.contentView = content
    defer { window.contentView = nil }
    let firstID = UUID(), secondID = UUID(), tabID = UUID()
    let first = PaneDropHost(frame: NSRect(x: 0, y: 0, width: 200, height: 300))
    first.pageID = firstID; first.tabID = tabID
    let second = PaneDropHost(frame: NSRect(x: 200, y: 0, width: 200, height: 300))
    second.pageID = secondID; second.tabID = tabID
    content.addSubview(first); content.addSubview(second)
    func event(_ type: NSEvent.EventType, x: CGFloat, time: Double) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 100), modifierFlags: [],
            timestamp: time, windowNumber: window.windowNumber, context: nil, eventNumber: Int(time), clickCount: 1, pressure: 1))
    }
    let down = try event(.leftMouseDown, x: 100, time: 1)
    InputDiagnostics.record(.application, event: down)
    InputDiagnostics.record(.window, event: down)
    first.isHidden = true
    first.removeFromSuperview()
    // Pointer and receiving view changed, but the release still belongs to firstID.
    InputDiagnostics.record(.appKit, event: try event(.leftMouseDragged, x: 250, time: 2), view: second)
    InputDiagnostics.record(.appKit, event: try event(.leftMouseDragged, x: 260, time: 3), view: second)
    InputDiagnostics.record(.window, event: try event(.leftMouseUp, x: 250, time: 4))
    InputDiagnostics.transition(.paneMove, .finished, paneID: firstID, tabID: tabID, relatedPaneID: secondID)
    // A new press in window chrome must not inherit the old pane ID.
    InputDiagnostics.record(.window, event: try event(.leftMouseDown, x: 500, time: 5))
    let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 6,
        windowNumber: window.windowNumber, context: nil, characters: "private-input", charactersIgnoringModifiers: "private-input",
        isARepeat: false, keyCode: 0))
    InputDiagnostics.record(.application, event: key)
    let controller = PageController(address: "browse://start", paneID: firstID) { $0.websiteDataStore = .nonPersistent() }
    let originalWeb = controller.webView
    let replacementConfiguration = WKWebViewConfiguration()
    replacementConfiguration.websiteDataStore = .nonPersistent()
    // Exercise the actual replacement path without loading external content.
    controller.navigateExtension(URL(string: "browse://start")!, configuration: replacementConfiguration)
    #expect(controller.webView !== originalWeb)
    #expect(controller.webView.diagnosticPaneID == firstID)
    controller.navigate("browse://start")
    #expect(controller.webView.diagnosticPaneID == firstID)
    InputDiagnostics.flush()
    let inputs = try traceRows(root, "events")
    let activities = try traceRows(root, "panes")
    #expect(inputs.count == 6)
    #expect(inputs.prefix(5).allSatisfy { $0["paneID"] as? String == firstID.uuidString })
    #expect(inputs[2]["receiverPaneID"] as? String == secondID.uuidString)
    #expect(inputs[5]["paneID"] is NSNull)
    #expect(inputs[5]["scope"] as? String == "non-pane")
    #expect(activities.contains { $0["stage"] as? String == "paneRoot" && $0["outcome"] as? String == "detached" && $0["paneID"] as? String == firstID.uuidString })
    #expect(activities.contains { $0["stage"] as? String == "paneMove" && $0["paneID"] as? String == firstID.uuidString && $0["tabID"] as? String == tabID.uuidString })
    let replacements = activities.filter { $0["stage"] as? String == "webReplacement" }
    #expect(replacements.count == 5)
    #expect(replacements.allSatisfy { $0["paneID"] as? String == firstID.uuidString })
    let createdViews = replacements.filter { ["created", "finished"].contains($0["outcome"] as? String ?? "") }
        .compactMap { ($0["ancestry"] as? [[String: Any]])?.first?["id"] as? Int }
    #expect(Set(createdViews).count == 3)
    #expect(activities.contains { $0["stage"] as? String == "paneVisibility" && $0["outcome"] as? String == "hidden" && $0["paneID"] as? String == firstID.uuidString })
    #expect(Set((inputs + activities).compactMap { $0["run"] as? String }).count == 1)
    let sequences = (inputs + activities).compactMap { $0["sequence"] as? Int }
    #expect(Set(sequences).count == sequences.count)
    #expect(!(try String(contentsOf: root.appendingPathComponent("events.jsonl"), encoding: .utf8)).contains("private-input"))
}

private func traceRows(_ root: URL, _ stream: String) throws -> [[String: Any]] {
    try Data(contentsOf: root.appendingPathComponent("\(stream).jsonl")).split(separator: 10).map {
        try #require(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
    }
}

// @lat: [[tests#Input diagnostics during hosting teardown]]
@Test @MainActor func inputTraceHostingTeardown() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseTraceTeardown-\(UUID())")
    InputDiagnostics.start(root: root)
    defer { InputDiagnostics.stop(); try? FileManager.default.removeItem(at: root) }
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    let paneID = store.selectedTab.focusedPane
    let window = BrowseWindow(contentRect: NSRect(x: -10000, y: -10000, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.orderOut(nil); window.contentView = nil }
    weak var retiredHost: NSView?
    weak var retiredHandle: PaneDragSourceView?
    func handle(in view: NSView) -> PaneDragSourceView? {
        if let result = view as? PaneDragSourceView { return result }
        return view.subviews.lazy.compactMap { handle(in: $0) }.first
    }
    for _ in 0..<4 {
        try autoreleasepool {
            let host = NSHostingView(rootView: PaneDragHandle(store: store, tabID: store.selectedTab.id,
                                                            pageID: paneID, title: "Fixture"))
            host.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
            window.contentView = host
            window.orderFront(nil)
            host.layoutSubtreeIfNeeded()
            retiredHost = host
            retiredHandle = try #require(handle(in: host))
            // Keep tracing active as the hosting view destroys its SwiftUI graph.
            window.contentView = nil
        }
        for _ in 0..<20 {
            if retiredHost == nil && retiredHandle == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(retiredHost == nil)
        #expect(retiredHandle == nil)
    }
    InputDiagnostics.flush()
    let rows = try traceRows(root, "panes")
    let removals = rows.filter { $0["stage"] as? String == "paneHandleLifetime" && $0["outcome"] as? String == "removed" }
    #expect(removals.count == 4)
    #expect(removals.allSatisfy { $0["paneID"] as? String == paneID.uuidString })
}
