import Foundation
import WebKit

// @lat: [[architecture#Extension diagnostic log]]
@MainActor
final class ExtensionDiagnostics {
    enum Event: String, Codable {
        case hostStarted, hostStopping, signingPreflight, metadataReadFailed, restoreStarted, restoreFinished
        case extensionImported, extensionRestored, extensionPageReady, javascriptError, extensionLoaded, extensionDisabled, extensionRemoved, extensionUpdated, extensionLoadFailed
        case runtimeError, wasmOperation, snapshot, nativeRequested, nativeResolved, nativeRejected
        case nativeStarted, nativeFirstSend, nativeFirstReceive, nativeClosed, nativeExited, nativeProtocolStatus
    }
    struct Entry: Codable {
        let time: Date
        let run: UUID
        let event: Event
        let extensionID: UUID?
        let connectionID: UUID?
        let fields: [String: String]
    }
    let run = UUID()
    let file: URL
    let previousFile: URL
    let maximumBytes: Int
    private(set) var writeFailed = false
    var changed: (() -> Void)?
    private var recent: [Entry] = []
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    init(root: URL, maximumBytes: Int = 256 * 1024) {
        self.maximumBytes = maximumBytes
        file = root.appendingPathComponent("diagnostics.jsonl")
        previousFile = root.appendingPathComponent("diagnostics.previous.jsonl")
    }
    // Fields are host-generated metadata only. Never pass URLs, JS error text,
    // native-message payloads, helper stderr, account data, or filesystem paths.
    func record(_ event: Event, extensionID: UUID? = nil, connectionID: UUID? = nil, fields: [String: String] = [:]) {
        let entry = Entry(time: Date(), run: run, event: event, extensionID: extensionID, connectionID: connectionID, fields: fields)
        recent.append(entry)
        if recent.count > 500 { recent.removeFirst(recent.count - 500) }
        do {
            var data = try encoder.encode(entry); data.append(10)
            guard data.count <= maximumBytes else { throw CocoaError(.fileWriteUnknown) }
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
            if size + data.count > maximumBytes {
                if FileManager.default.fileExists(atPath: previousFile.path) { try FileManager.default.removeItem(at: previousFile) }
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.moveItem(at: file, to: previousFile) }
            }
            if !FileManager.default.fileExists(atPath: file.path) {
                guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: data)
        } catch { writeFailed = true }
        changed?()
    }
    func report() -> String {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var entries: [Entry] = []
        for url in [previousFile, file] {
            guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue, size <= maximumBytes,
                  let data = try? Data(contentsOf: url) else { continue }
            entries += data.split(separator: 10).compactMap { try? decoder.decode(Entry.self, from: Data($0)) }
        }
        if writeFailed { entries.removeAll { $0.run == run }; entries += recent }
        return "Bend extension diagnostics v1\nPayloads, credentials, URLs, helper stderr, and raw error text are excluded.\nDisk logging: \(writeFailed ? "failed; current-session memory fallback included" : "active")\n" + entries.suffix(1000).compactMap {
            (try? encoder.encode($0)).flatMap { String(data: $0, encoding: .utf8) }
        }.joined(separator: "\n")
    }
    static func errorFields(_ error: Error) -> [String: String] {
        let ns = error as NSError
        let domain: String
        switch ns.domain {
        case NSCocoaErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain, "WKErrorDomain", "WKWebExtensionContextErrorDomain", "WKWebExtensionMessagePortErrorDomain": domain = ns.domain
        default: domain = error is NativeMessagingError ? "Browse.NativeMessaging" : "other"
        }
        let message = error.localizedDescription.lowercased()
        let category: String
        switch message {
        case let s where s.contains("wasm is not initialized"): category = "wasm-not-initialized"
        case let s where s.contains("chrome.privacy.services"): category = "privacy-api-unavailable"
        case let s where s.contains("database connection"): category = "database-connection-closed"
        case let s where s.contains("not installed"): category = "native-host-not-installed"
        case let s where s.contains("does not authorize"): category = "native-host-authorization-or-executable"
        case let s where s.contains("permission"): category = "permission"
        case let s where s.contains("timed out"): category = "timeout"
        case let s where s.contains("incomplete message"): category = "incomplete-frame"
        case let s where s.contains("invalid message"): category = "invalid-frame"
        case let s where s.contains("disconnected"): category = "disconnected"
        case let s where s.contains("contextmenu"): category = "context-menu"
        default: category = "other"
        }
        return ["errorDomain": domain, "errorCode": String(ns.code), "category": category]
    }
    static func applicationLabel(_ name: String?) -> String {
        switch name {
        case "com.1password.1password": "1password8"
        case "com.1password.1password7": "1password7"
        case nil: "unspecified"
        default: "other"
        }
    }
}

@available(macOS 15.4, *)
extension ExtensionManager {
    func logSnapshot(_ event: ExtensionDiagnostics.Event = .snapshot, context: WKWebExtensionContext) {
        let id = UUID(uuidString: context.uniqueIdentifier)
        let store = context.webViewConfiguration?.websiteDataStore
        diagnostics.record(event, extensionID: id, fields: [
            "loaded": String(context.isLoaded), "nativePermission": String(context.hasPermission(.init(rawValue: "nativeMessaging"))),
            "websiteDataPersistent": store.map { String($0.isPersistent) } ?? "unavailable",
            "websiteStore": store?.identifier?.uuidString ?? "default",
            "contextMatchesOrigin": String(context.baseURL.host?.lowercased() == context.uniqueIdentifier.lowercased()),
            "errorCount": String(context.errors.count)
        ])
        logRuntimeErrors(context)
    }
    func logRuntimeErrors(_ context: WKWebExtensionContext) {
        guard contexts.values.contains(where: { $0 === context }),
              let id = UUID(uuidString: context.uniqueIdentifier) else { return }
        for error in context.errors {
            let fields = ExtensionDiagnostics.errorFields(error)
            let key = fields.keys.sorted().map { $0 + "=" + (fields[$0] ?? "") }.joined(separator: "|")
            if diagnosticErrors[id, default: []].insert(key).inserted {
                diagnostics.record(.runtimeError, extensionID: id, fields: fields)
            }
        }
    }
    func diagnosticReport() -> String {
        for context in contexts.values { logSnapshot(context: context) }
        return diagnostics.report()
    }
}
