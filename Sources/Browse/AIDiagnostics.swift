import AppKit
import Combine

// @lat: [[lat.md/architecture/ai#AI debugging]]
@MainActor final class AIDiagnostics: ObservableObject {
    static let shared = AIDiagnostics()
    static let preferenceKey = "aiDebuggingEnabled"
    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: Self.preferenceKey)
            if !enabled { writer.flush() }
        }
    }
    @Published private(set) var error: String?
    let root: URL
    private let defaults: UserDefaults
    private let writer: InputTraceFile
    private let run = UUID().uuidString
    private var sequence = 0

    init(defaults: UserDefaults = AppProfile.current.defaults, root: URL? = nil) {
        self.defaults = defaults
        self.root = root ?? AppProfile.current.supportDirectory.appendingPathComponent("AIDiagnostics", isDirectory: true)
        enabled = defaults.bool(forKey: Self.preferenceKey)
        writer = InputTraceFile(root: self.root, stream: .ai)
    }
    func record(_ event: String, tab: UUID? = nil, fields: [String: String] = [:]) {
        guard enabled else { return }
        sequence += 1
        var record = fields.mapValues { String($0.prefix(4096)) }
        record["event"] = event
        record["run"] = run
        record["sequence"] = String(sequence)
        record["time"] = ISO8601DateFormatter().string(from: Date())
        record["tab"] = tab?.uuidString
        guard var data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        data.append(0x0a)
        _ = writer.enqueue(data)
    }
    static func safeURL(_ value: String) -> String {
        guard var url = URLComponents(string: value) else { return "invalid-url" }
        url.user = nil; url.password = nil; url.fragment = nil
        url.queryItems = url.queryItems?.map { URLQueryItem(name: $0.name, value: "redacted") }
        return url.string ?? "invalid-url"
    }
    func flush() { writer.flush() }
    func reveal() {
        flush()
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            NSWorkspace.shared.open(root)
        } catch { self.error = "Could not open the AI debugging folder." }
    }
    func clear() {
        flush()
        do {
            for name in ["ai.jsonl", "ai.previous.jsonl"] {
                let file = root.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            }
            error = nil
        } catch { self.error = "Could not clear the AI debugging logs." }
    }
}
