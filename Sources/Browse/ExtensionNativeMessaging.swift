import Foundation
import WebKit
import Combine
import Darwin

struct NativeHost: Sendable {
    let executable: URL
    let arguments: [String]

    static func resolve(_ name: String, extensionID: String, directories: [URL]? = nil) throws -> NativeHost {
        guard !name.isEmpty, name.utf8.count < 256,
              name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({
                  !$0.isEmpty && $0.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }
              }) else { throw NativeMessagingError("Invalid native application name.") }
        let roots = directories ?? [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Mozilla/NativeMessagingHosts"),
            URL(fileURLWithPath: "/Library/Application Support/Mozilla/NativeMessagingHosts")
        ]
        struct Manifest: Decodable { let name: String; let path: String; let type: String; let allowed_extensions: [String] }
        for root in roots {
            let url = root.appendingPathComponent(name + ".json")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let data = try Data(contentsOf: url)
            guard data.count <= 65536 else { throw NativeMessagingError("Native application manifest is too large.") }
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            guard manifest.name == name, manifest.type == "stdio", manifest.path.hasPrefix("/"),
                  manifest.allowed_extensions.contains(extensionID),
                  FileManager.default.isExecutableFile(atPath: manifest.path) else {
                throw NativeMessagingError("Native application does not authorize this extension or its executable is unavailable.")
            }
            return NativeHost(executable: URL(fileURLWithPath: manifest.path), arguments: [url.path, extensionID])
        }
        throw NativeMessagingError("Native application is not installed. Install its desktop app first.")
    }
}

struct NativeMessagingError: LocalizedError, Sendable {
    let errorDescription: String?
    init(_ description: String) { errorDescription = description }
}

struct NativeMessageFrames {
    static let maximum = 1024 * 1024
    private var buffer = Data()
    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var result: [Data] = []
        while buffer.count >= 4 {
            let size = buffer.prefix(4).enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
            guard size > 0, size <= Self.maximum else { throw NativeMessagingError("Invalid native message length.") }
            guard buffer.count >= size + 4 else { break }
            let payload = Data(buffer.dropFirst(4).prefix(size))
            _ = try JSONSerialization.jsonObject(with: payload, options: .fragmentsAllowed)
            result.append(payload)
            buffer = Data(buffer.dropFirst(size + 4))
        }
        return result
    }
    var isEmpty: Bool { buffer.isEmpty }
    static func encode(_ message: Any) throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: message, options: .fragmentsAllowed)
        guard payload.count <= maximum else { throw NativeMessagingError("Native message exceeds Bend's 1 MiB limit.") }
        var size = UInt32(payload.count).littleEndian
        return withUnsafeBytes(of: &size) { Data($0) } + payload
    }
}

// Pipes carry opaque extension messages; never log their contents.
@MainActor
final class NativeMessageConnection {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let writer = DispatchQueue(label: "Browse.native-messaging.write")
    private var pendingBytes = 0
    private var frames = NativeMessageFrames()
    private(set) var closed = false
    var received: ((Any) -> Void)?
    var ended: ((Error?) -> Void)?
    var diagnostic: (@MainActor @Sendable (ExtensionDiagnostics.Event, [String: String]) -> Void)?
    var messageMetadata: ((Any) -> [String: String])?
    private var sentCount = 0
    private(set) var receivedCount = 0

    func start(_ host: NativeHost) throws {
        process.executableURL = host.executable
        process.arguments = host.arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let report = diagnostic
        process.terminationHandler = { process in
            let fields = ["exitStatus": String(process.terminationStatus), "terminationReason": process.terminationReason == .exit ? "exit" : "signal"]
            Task { @MainActor in report?(.nativeExited, fields) }
        }
        try process.run()
        diagnostic?(.nativeStarted, ["pid": String(process.processIdentifier)])
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        let handle = output.fileHandleForReading
        // A pipe may stay idle indefinitely. Never occupy a Swift cooperative
        // worker with its blocking read: a few connections can starve async work.
        DispatchQueue(label: "Browse.native-messaging.read").async { [weak self] in
            defer { try? handle.close() }
            do {
                while true {
                    let data = try Self.readChunk(handle)
                    if data.isEmpty { break }
                    guard DispatchQueue.main.sync(execute: { [weak self] in self?.accept(data) == true }) else { return }
                }
                DispatchQueue.main.async { [weak self] in self?.eof() }
            } catch {
                DispatchQueue.main.async { [weak self] in self?.finish(NativeMessagingError("Native application connection closed.")) }
            }
        }
    }
    nonisolated private static func readChunk(_ handle: FileHandle) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: 65536)
        var count: Int
        repeat { count = Darwin.read(handle.fileDescriptor, &buffer, buffer.count) } while count < 0 && errno == EINTR
        guard count >= 0 else { throw NativeMessagingError("Native application pipe failed.") }
        return Data(buffer.prefix(count))
    }
    private func accept(_ data: Data) -> Bool {
        guard !closed else { return false }
        do {
            for payload in try frames.append(data) {
                guard !closed else { break }
                receivedCount += 1
                if receivedCount == 1 { diagnostic?(.nativeFirstReceive, ["bytes": String(payload.count)]) }
                let message = try JSONSerialization.jsonObject(with: payload, options: .fragmentsAllowed)
                if let fields = messageMetadata?(message), receivedCount == 1 || fields["protocolType"] == "Failure" || fields["protocolType"] == "BrowserSupport" {
                    diagnostic?(.nativeProtocolStatus, fields)
                }
                received?(message)
            }
        } catch { finish(NativeMessagingError("Native application sent an invalid message.")) }
        return !closed
    }
    private func eof() {
        finish(NativeMessagingError(frames.isEmpty
            ? "Native application disconnected. For 1Password, add Bend in desktop Settings → Browser → Add Browser."
            : "Native application sent an incomplete message."))
    }
    func send(_ message: Any) throws {
        guard !closed else { throw NativeMessagingError("Native application is disconnected.") }
        let frame = try NativeMessageFrames.encode(message)
        guard pendingBytes + frame.count <= 4 * NativeMessageFrames.maximum else {
            throw NativeMessagingError("Native application is not accepting messages.")
        }
        pendingBytes += frame.count
        sentCount += 1
        if sentCount == 1 { diagnostic?(.nativeFirstSend, ["bytes": String(frame.count - 4)]) }
        let handle = input.fileHandleForWriting
        writer.async { [weak self] in
            var failed = false
            do { try handle.write(contentsOf: frame) } catch { failed = true }
            let didFail = failed
            Task { @MainActor [weak self] in
                self?.pendingBytes -= frame.count
                if didFail { self?.finish(NativeMessagingError("Could not send to native application.")) }
            }
        }
    }
    func finish(_ error: Error? = nil) {
        guard !closed else { return }
        closed = true
        var fields = error.map(ExtensionDiagnostics.errorFields) ?? [:]
        fields["sentMessages"] = String(sentCount); fields["receivedMessages"] = String(receivedCount)
        fields["reason"] = error == nil ? "normal" : "error"
        diagnostic?(.nativeClosed, fields)
        Self.terminate(process)
        try? input.fileHandleForWriting.close()
        received = nil
        let callback = ended; ended = nil
        callback?(error)
    }
    nonisolated private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
    deinit {
        Self.terminate(process)
        try? input.fileHandleForWriting.close()
    }
}

// @lat: [[lat.md/architecture/extensions/compatibility#Native extension messaging]]
@available(macOS 15.4, *)
@MainActor
final class ExtensionNativeMessaging {
    weak var manager: ExtensionManager?
    var resolve: (String, String) throws -> NativeHost = { try NativeHost.resolve($0, extensionID: $1) }
    private struct Session {
        let context: WKWebExtensionContext
        let connection: NativeMessageConnection
    }
    private var sessions: [UUID: Session] = [:]
    private var observations: [AnyCancellable] = []
    var count: Int { sessions.count }
    func status(for context: WKWebExtensionContext) -> String {
        let active = sessions.values.filter { $0.context === context }
        guard !active.isEmpty else { return "No active desktop connection" }
        let received = active.reduce(0) { $0 + $1.connection.receivedCount }
        return "Native helper running · \(received) messages received (unlock status unknown)"
    }

    init() {
        for name in [WKWebExtensionContext.permissionsWereDeniedNotification, WKWebExtensionContext.grantedPermissionsWereRemovedNotification] {
            observations.append(NotificationCenter.default.publisher(for: name).receive(on: RunLoop.main).sink { [weak self] _ in
                guard let self else { return }
                for session in Array(self.sessions.values) where !self.authorized(session.context) { self.stop(session.context) }
            })
        }
    }
    func authorized(_ context: WKWebExtensionContext) -> Bool {
        guard let manager, context.isLoaded,
              manager.contexts.values.contains(where: { $0 === context }) else { return false }
        return context.hasPermission(.init(rawValue: "nativeMessaging"))
    }
    private func host(_ name: String?, context: WKWebExtensionContext, connectionID: UUID) throws -> NativeHost {
        manager?.diagnostics.record(.nativeRequested, extensionID: UUID(uuidString: context.uniqueIdentifier), connectionID: connectionID,
            fields: ["application": ExtensionDiagnostics.applicationLabel(name), "authorized": String(authorized(context))])
        do {
            guard sessions.values.filter({ $0.context === context }).count < 16 else { throw NativeMessagingError("Too many native application connections.") }
            guard authorized(context), let name else { throw NativeMessagingError("Native messaging permission is required.") }
            let manifest = context.webExtension.manifest
            let settings = manifest["browser_specific_settings"] as? [String: Any] ?? manifest["applications"] as? [String: Any]
            guard let gecko = settings?["gecko"] as? [String: Any], let id = gecko["id"] as? String, !id.isEmpty else {
                throw NativeMessagingError("Native messaging requires a Firefox extension identity; Safari app-extension handlers are unsupported.")
            }
            let result = try resolve(name, id)
            manager?.diagnostics.record(.nativeResolved, extensionID: UUID(uuidString: context.uniqueIdentifier), connectionID: connectionID,
                fields: ["application": ExtensionDiagnostics.applicationLabel(name)])
            return result
        } catch {
            var fields = ExtensionDiagnostics.errorFields(error)
            fields["application"] = ExtensionDiagnostics.applicationLabel(name)
            manager?.diagnostics.record(.nativeRejected, extensionID: UUID(uuidString: context.uniqueIdentifier), connectionID: connectionID, fields: fields)
            throw error
        }
    }
    private func connection(_ id: UUID, name: String?, context: WKWebExtensionContext, mode: String) -> NativeMessageConnection {
        let connection = NativeMessageConnection()
        let logger = manager?.diagnostics, extensionID = UUID(uuidString: context.uniqueIdentifier)
        let application = ExtensionDiagnostics.applicationLabel(name)
        if application == "1password8" || application == "1password7" { connection.messageMetadata = OnePasswordProtocolSummary.fields }
        connection.diagnostic = { event, fields in
            var fields = fields; fields["application"] = application; fields["mode"] = mode
            logger?.record(event, extensionID: extensionID, connectionID: id, fields: fields)
        }
        return connection
    }
    func stop(_ context: WKWebExtensionContext) {
        for session in Array(sessions.values) where session.context === context {
            session.connection.finish(NativeMessagingError("Extension native messaging was stopped."))
        }
    }
    func connect(_ port: WKWebExtension.MessagePort, context: WKWebExtensionContext) throws {
        let id = UUID()
        let host = try host(port.applicationIdentifier, context: context, connectionID: id)
        let connection = connection(id, name: port.applicationIdentifier, context: context, mode: "port")
        connection.received = { [weak self, weak connection] message in
            guard self?.authorized(context) == true else { connection?.finish(NativeMessagingError("Native messaging permission was removed.")); return }
            port.sendMessage(message) { error in if let error { connection?.finish(error) } }
        }
        connection.ended = { [weak self] error in
            port.messageHandler = nil; port.disconnectHandler = nil
            port.disconnect(throwing: error)
            self?.sessions.removeValue(forKey: id)
        }
        port.messageHandler = { [weak self, weak connection] message, error in
            guard self?.authorized(context) == true else { connection?.finish(NativeMessagingError("Native messaging permission was removed.")); return }
            do {
                if let error { throw error }
                try connection?.send(message ?? NSNull())
            } catch { connection?.finish(error) }
        }
        port.disconnectHandler = { [weak connection] error in connection?.finish(error) }
        sessions[id] = Session(context: context, connection: connection)
        do { try connection.start(host) } catch { connection.finish(error); throw error }
    }
    func send(_ message: Any, name: String?, context: WKWebExtensionContext, reply: @escaping (Any?, Error?) -> Void) {
        do {
            let id = UUID()
            let host = try host(name, context: context, connectionID: id)
            let connection = connection(id, name: name, context: context, mode: "one-shot")
            var replied = false
            connection.received = { [weak self, weak connection] response in
                guard self?.authorized(context) == true else { connection?.finish(NativeMessagingError("Native messaging permission was removed.")); return }
                guard !replied else { return }; replied = true
                reply(response, nil); connection?.finish()
            }
            connection.ended = { [weak self] error in
                self?.sessions.removeValue(forKey: id)
                if !replied { replied = true; reply(nil, error ?? NativeMessagingError("Native application disconnected.")) }
            }
            sessions[id] = Session(context: context, connection: connection)
            do { try connection.start(host); try connection.send(message) }
            catch { connection.finish(error) }
            Task { [weak connection] in
                try? await Task.sleep(for: .seconds(30))
                connection?.finish(NativeMessagingError("Native application response timed out."))
            }
        } catch { reply(nil, error) }
    }
}
