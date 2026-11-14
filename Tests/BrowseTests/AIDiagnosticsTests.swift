import Foundation
import Testing
@testable import Browse

// @lat: [[lat.md/tests/ai-tests#AI debugging]]
@Test @MainActor func aiDebugging() throws {
    let name = "AIDiagnostics-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: name))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
    defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
    let diagnostics = AIDiagnostics(defaults: defaults, root: root)
    let file = root.appendingPathComponent("ai.jsonl")
    diagnostics.record("disabled")
    diagnostics.flush()
    #expect(!FileManager.default.fileExists(atPath: file.path))
    diagnostics.enabled = true
    let safe = AIDiagnostics.safeURL("https://user:password@example.com/item?id=123&token=secret#private")
    #expect(!safe.contains("password") && !safe.contains("123") && !safe.contains("secret") && !safe.contains("private"))
    diagnostics.record("citation.decoded", tab: UUID(), fields: ["selector": "#\\35 0489641", "source": safe])
    diagnostics.flush()
    let first = try Data(contentsOf: file)
    let object = try #require(JSONSerialization.jsonObject(with: first) as? [String: String])
    #expect(object["selector"] == "#\\35 0489641")
    #expect(object["event"] == "citation.decoded")
    #expect(AIDiagnostics(defaults: defaults, root: root).enabled)
    diagnostics.enabled = false
    diagnostics.record("disabled-again")
    diagnostics.flush()
    #expect(try Data(contentsOf: file) == first)
    diagnostics.clear()
    #expect(!FileManager.default.fileExists(atPath: file.path))
}
