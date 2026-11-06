import AppKit
import WebKit

// @lat: [[architecture#Native input diagnostics]]
@MainActor
final class InputDiagnostics {
    static let enabledPreferenceKey = "inputAndPaneLoggingEnabled"

    static func applyPreferences(defaults: UserDefaults = .standard, root: URL? = nil) {
        if defaults.bool(forKey: enabledPreferenceKey) {
            start(root: root)
        } else {
            stop()
        }
    }

    enum Stage: String {
        case application, applicationReturned, window, appKit, appKitReturned, webView, webViewReturned
        case paneConsumed, paneHandle, tabMonitor, tabMonitorConsumed, tabMonitorReturned, tabHandle, sidebarResize
    }
    enum Action: String {
        case launch, appActivation, windowOpen, windowKey, windowClose, firstResponder
        case monitorFocus, webFocus, webAttachment, webReplacement, webLoad, webProcessExit
        case paneOwnership, paneHandleLifetime, paneDrag, paneDrop, paneHoverSelection
        case tabHandleLifetime, tabDrag, tabDrop, tabHoverSelection, tabMonitorLifetime, sidebarResizeLifetime, dividerResize
        case storeFocus, storeSelection, storeZoom, addressRequest, addressPanel, addressSubmit, addressCancel
        case mountedTab, mountedTabRoot, mountedTabVisibility, mountedTabFocus
        case canvasScroll, paneRoot, paneMembership, paneMove, paneGeometry, paneVisibility, surfaceAttachment, surfaceInset
        case navigationPolicy, commandLink, newWindowLink, javascriptDialog
        case findBar, findAction
        case extensionConfiguration, extensionActivation, extensionPopup, extensionPermission, extensionWindowFocus, extensionTabAction
    }
    enum Outcome: String {
        case requested, started, finished, changed, unchanged, ignored, cancelled
        case allowed, denied, attached, detached, shown, hidden, created, removed, replaced
    }

    private static var shared: InputDiagnostics?
    private let output: InputTraceFile
    private let activity: InputTraceFile
    private let run = UUID().uuidString
    private var droppedRecords: [InputTraceFile.Stream: Int] = [:]
    private final class Gesture: NSObject {
        let timestamp: TimeInterval
        let paneID: UUID?
        init(timestamp: TimeInterval, paneID: UUID?) { self.timestamp = timestamp; self.paneID = paneID }
    }
    private let gestures = NSMapTable<NSWindow, Gesture>(keyOptions: [.weakMemory, .objectPointerPersonality], valueOptions: .strongMemory)
    private var sequence = 0

    static func start(root: URL? = nil) {
        guard shared == nil else { return }
        let directory = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("BrowsePrototype/InputDiagnostics", isDirectory: true)
        if let directory { shared = InputDiagnostics(root: directory) }
    }

    static func flush() { shared?.output.flush(); shared?.activity.flush() }
    static func stop() { flush(); shared = nil }

    private init(root: URL) {
        output = InputTraceFile(root: root)
        activity = InputTraceFile(root: root, stream: .panes)
    }

    static func record(_ stage: Stage, event: NSEvent, view: NSView? = nil) {
        guard [.leftMouseDown, .leftMouseDragged, .leftMouseUp].contains(event.type), let shared else { return }
        shared.write(stage.rawValue, event: event, view: view, stream: .events)
    }

    static func transition(_ action: Action, _ outcome: Outcome, event: NSEvent? = nil,
                           view: NSView? = nil, window: NSWindow? = nil, paneID: UUID? = nil,
                           tabID: UUID? = nil, relatedPaneID: UUID? = nil, flags: [String: Bool] = [:]) {
        shared?.write(action.rawValue, event: event ?? NSApp?.currentEvent, view: view,
                      window: window, outcome: outcome, paneID: paneID, tabID: tabID,
                      relatedPaneID: relatedPaneID, flags: flags, stream: .panes)
    }

    private func paneID(for view: NSView?) -> UUID? {
        var current = view
        while let item = current {
            if let web = item as? FocusWebView, let id = web.diagnosticPaneID { return id }
            if let handle = item as? PaneDragSourceView, let id = handle.pageID { return id }
            if let host = item as? PaneDropHost, let id = host.pageID { return id }
            current = item.superview
        }
        return nil
    }

    private func identity(_ object: AnyObject) -> Int {
        // SwiftUI dismantles children from NSHostingView.deinit. An ancestor
        // encountered here can already be deallocating, so registering even a
        // weak reference to it aborts in objc_storeWeak. Hash its identity
        // without storing any reference or exposing the raw address instead.
        // Addresses may be reused after destruction: paneID is the durable ID.
        ObjectIdentifier(object).hashValue
    }

    private func write(_ stage: String, event: NSEvent?, view: NSView?, window suppliedWindow: NSWindow? = nil,
                       outcome: Outcome? = nil, paneID suppliedPaneID: UUID? = nil, tabID: UUID? = nil,
                       relatedPaneID: UUID? = nil, flags: [String: Bool] = [:], stream: InputTraceFile.Stream) {
        let window = suppliedWindow ?? view?.window ?? event?.window
        var hit: NSView?
        if stream == .events, let event, [.leftMouseDown, .leftMouseDragged, .leftMouseUp].contains(event.type),
           let content = window?.contentView {
            hit = content.hitTest(content.convert(event.locationInWindow, from: nil))
        }
        let receiverPaneID = paneID(for: view ?? hit)
        var ownerPaneID = suppliedPaneID ?? receiverPaneID
        if stream == .events, let event, let window {
            // Preserve the press target across moves, hiding, reparenting, and
            // every routing stage of the release. A new press starts a gesture.
            if event.type == .leftMouseDown, gestures.object(forKey: window)?.timestamp != event.timestamp {
                gestures.setObject(Gesture(timestamp: event.timestamp, paneID: paneID(for: hit) ?? receiverPaneID), forKey: window)
            }
            if let gesture = gestures.object(forKey: window) { ownerPaneID = gesture.paneID }
        }
        sequence += 1
        var fields: [String: Any] = [
            "run": run, "sequence": sequence, "droppedRecords": droppedRecords[stream, default: 0],
            "paneID": ownerPaneID.map { $0.uuidString as Any } ?? NSNull(),
            "scope": ownerPaneID == nil ? "non-pane" : "pane",
            "stage": stage, "time": ProcessInfo.processInfo.systemUptime, "wallTime": Date().timeIntervalSince1970,
            "appActive": NSApp?.isActive ?? false, "keyWindow": window?.isKeyWindow ?? false,
            "mainWindow": window?.isMainWindow ?? false,
            "windowVisible": window?.isVisible ?? false,
            "paneCapture": (window as? BrowseWindow)?.capturesPaneGesture ?? false
        ]
        if let event, [.leftMouseDown, .leftMouseDragged, .leftMouseUp].contains(event.type) {
            fields["type"] = event.type.rawValue
            fields["event"] = event.eventNumber
            fields["eventTime"] = event.timestamp
        }
        if let outcome { fields["outcome"] = outcome.rawValue }
        if let tabID { fields["tabID"] = tabID.uuidString }
        if let relatedPaneID { fields["relatedPaneID"] = relatedPaneID.uuidString }
        if stream == .events {
            fields["receiverPaneID"] = receiverPaneID.map { $0.uuidString as Any } ?? NSNull()
        }
        if !flags.isEmpty { fields["flags"] = flags }
        if let window { fields["window"] = identity(window) }
        if let responder = window?.firstResponder {
            fields["firstResponderClass"] = NSStringFromClass(type(of: responder))
            fields["firstResponder"] = identity(responder)
        }
        // Only native classes, local identities, visibility, and recognizer states.
        // Never record coordinates, URLs, titles, DOM data, or keyboard events.
        var ancestry: [[String: Any]] = []
        var current = view ?? hit
        if let web = current as? WKWebView {
            fields["userScriptCount"] = web.configuration.userContentController.userScripts.count
            fields["persistentWebsiteData"] = web.configuration.websiteDataStore.isPersistent
            if #available(macOS 15.4, *) {
                fields["extensionControllerAttached"] = web.configuration.webExtensionController != nil
            }
        }
        while let item = current, ancestry.count < 12 {
            ancestry.append([
                "class": NSStringFromClass(type(of: item)), "id": identity(item),
                "hidden": item.isHiddenOrHasHiddenAncestor,
                "inWindow": item.window != nil, "emptyBounds": item.bounds.isEmpty,
                "emptyVisibleRect": item.visibleRect.isEmpty,
                "gestures": item.gestureRecognizers.map {
                    ["class": NSStringFromClass(type(of: $0)), "state": $0.state.rawValue,
                     "enabled": $0.isEnabled] as [String: Any]
                }
            ])
            current = item.superview
        }
        fields["ancestry"] = ancestry
        guard var data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return }
        data.append(10)
        let writer = stream == .events ? output : activity
        if writer.enqueue(data) { droppedRecords[stream] = 0 }
        else { droppedRecords[stream, default: 0] += 1 }
    }
}

// File work is confined to one serial queue. The semaphore bounds pending data
// without blocking input delivery when the disk cannot keep up.
final class InputTraceFile: @unchecked Sendable {
    enum Stream: String { case events, panes }
    let stream: Stream
    let root: URL
    let maximumBytes: Int
    private let queue = DispatchQueue(label: "Browse.input-diagnostics", qos: .utility)
    private let pending = DispatchSemaphore(value: 64)

    init(root: URL, stream: Stream = .events, maximumBytes: Int = 500 * 1024) {
        self.stream = stream
        self.root = root
        self.maximumBytes = maximumBytes
    }

    func enqueue(_ data: Data) -> Bool {
        guard data.count <= maximumBytes, pending.wait(timeout: .now()) == .success else { return false }
        queue.async { [self] in
            defer { pending.signal() }
            try? append(data)
        }
        return true
    }

    func flush() { queue.sync {} }

    private func append(_ data: Data) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = root.appendingPathComponent("\(stream.rawValue).jsonl")
        let previous = root.appendingPathComponent("\(stream.rawValue).previous.jsonl")
        // Older builds used larger limits. Do not retain an oversized segment
        // when adopting a smaller cap, including the previous segment.
        for segment in [file, previous] {
            let bytes = (try? manager.attributesOfItem(atPath: segment.path)[.size] as? NSNumber)?.intValue ?? 0
            if bytes > maximumBytes { try manager.removeItem(at: segment) }
        }
        let size = (try? manager.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        if size + data.count > maximumBytes {
            if manager.fileExists(atPath: previous.path) { try manager.removeItem(at: previous) }
            try manager.moveItem(at: file, to: previous)
        }
        if !manager.fileExists(atPath: file.path) {
            guard manager.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
