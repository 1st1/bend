import AppKit
import AI
import BrowseCore
import Testing
@testable import Browse

// @lat: [[lat.md/tests/ai-tests#System and location approval]]
@Test @MainActor func aiSystemAndLocationApproval() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let domain = "AISystemTools-\(UUID())"
    let defaults = UserDefaults(suiteName: domain)!
    let settings = AISettings(defaults: defaults)
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    defer { store.stopWindow(); defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: root) }
    let approval = AIActionApproval()
    var systemReads = 0, locationReads = 0
    var revokeDuringLocation = false
    let tools = PaneChatTools(store: store, tabID: store.selectedTab.id, settings: settings, approve: approval.request,
        systemInfo: { systemReads += 1; return .string("system fixture") },
        currentLocation: {
            locationReads += 1
            if revokeDuringLocation { settings.setToolEnabled("get_current_location", enabled: false) }
            return .string("location fixture")
        })
    func pending() async throws -> AIActionApproval.Request {
        for _ in 0..<100 where approval.pending == nil { try await Task.sleep(for: .milliseconds(10)) }
        return try #require(approval.pending)
    }
    for name in ["get_system_info", "get_current_location"] {
        let denied = Task { try await tools.execute(name, input: .init()) }
        let request = try await pending()
        #expect(request.action.rawValue == name && request.fields.first?.label == "Share with AI")
        #expect(systemReads == 0 && locationReads == 0)
        approval.resolve(request.id, approved: false)
        await #expect(throws: Error.self) { try await denied.value }
    }
    let accepted = Task { try await tools.execute("get_system_info", input: .init()) }
    let request = try await pending()
    approval.resolve(request.id, approved: true)
    #expect(try await accepted.value == .string("system fixture"))
    #expect(systemReads == 1 && locationReads == 0)
    let revoked = Task { try await tools.execute("get_current_location", input: .init()) }
    let revokedRequest = try await pending()
    settings.setToolEnabled("get_current_location", enabled: false)
    approval.resolve(revokedRequest.id, approved: true)
    await #expect(throws: Error.self) { try await revoked.value }
    #expect(locationReads == 0)
    settings.setToolEnabled("get_current_location", enabled: true)
    let cancelled = Task { try await tools.execute("get_current_location", input: .init()) }
    _ = try await pending()
    cancelled.cancel()
    await #expect(throws: Error.self) { try await cancelled.value }
    #expect(locationReads == 0)
    let location = Task { try await tools.execute("get_current_location", input: .init()) }
    let locationRequest = try await pending()
    approval.resolve(locationRequest.id, approved: true)
    #expect(try await location.value == .string("location fixture"))
    #expect(locationReads == 1)
    revokeDuringLocation = true
    let lateRevoked = Task { try await tools.execute("get_current_location", input: .init()) }
    let lateRequest = try await pending()
    approval.resolve(lateRequest.id, approved: true)
    await #expect(throws: Error.self) { try await lateRevoked.value }
    #expect(locationReads == 2) // Approved acquisition may finish, but revoked data must not be returned.

    let unattended = PaneChatTools(store: store, tabID: store.selectedTab.id, settings: settings,
                                  systemInfo: { Issue.record("Read without approval"); return .null })
    await #expect(throws: Error.self) { try await unattended.execute("get_system_info", input: .init()) }
    let rounded = AISystemContext.systemInfo(now: Date(timeIntervalSince1970: 86399), timeZone: TimeZone(secondsFromGMT: 0)!, osVersion: "testOS")
    #expect(rounded["date"] == .string("1970-01-02"))
    #expect(rounded["time"] == .string("00:00"))
    #expect(rounded["os_version"] == .string("testOS"))
    let exact = AISystemContext.systemInfo(now: Date(timeIntervalSince1970: 60), timeZone: TimeZone(secondsFromGMT: 0)!)
    #expect(exact["time"] == .string("00:01"))
}

// @lat: [[lat.md/tests/ai-tests#Native changelog reads]]
@Test @MainActor func aiNativeChangelogReads() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let domain = "AIChangelog-\(UUID())"
    let defaults = UserDefaults(suiteName: domain)!
    let settings = AISettings(defaults: defaults)
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    defer { store.stopWindow(); defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: root) }
    store.showChangelog()
    let tab = store.selectedTab
    let pane = try #require(tab.pages.first)
    let controller = store.controller(for: pane)
    let tools = PaneChatTools(store: store, tabID: tab.id, settings: settings, approve: { _ in true },
        changelog: { Changelog(markdown: "## v1.2.0\n" + String(repeating: "🦋", count: 25000), releaseDates: ["1.2.0": "2026-11-15"]) })
    func decode(_ value: JSONValue) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(try #require(value.string).utf8))
    }
    let first = try decode(await tools.execute("read_pane", input: .init(pane: pane.id.uuidString)))
    #expect(first["has_more"] == .bool(true))
    #expect(first["text"]?.string?.contains("2026-11-15") == true)
    #expect(first["text"]?.string?.contains("Installed Bend version:") == true)
    #expect(first["text"]?.string?.unicodeScalars.count == 24000)
    let cursor = try #require(first["next_cursor"]?.string)
    let second = try decode(await tools.execute("read_pane", input: .init(cursor: cursor, pane: pane.id.uuidString)))
    #expect(second["has_more"] == .bool(false))
    let citation = try #require(first["citation"]?.string.flatMap(URL.init(string:)))
    try await ChatPageLinks.open(citation, tabID: tab.id, store: store)
    #expect(controller.address == "bend://log")
    await #expect(throws: Error.self) { try await tools.execute("read_pane", input: .init(cursor: cursor, pane: pane.id.uuidString)) }
    controller.navigate("bend://history")
    await #expect(throws: Error.self) { try await tools.execute("read_pane", input: .init(pane: pane.id.uuidString)) }
    _ = try await tools.execute("navigate_pane", input: .init(pane: pane.id.uuidString, url: "bend://log"))
    #expect(controller.address == "bend://log")
    await #expect(throws: Error.self) { try await tools.execute("click_element", input: .init(pane: pane.id.uuidString, selector: "body")) }
    await #expect(throws: Error.self) { try await tools.execute("navigate_pane", input: .init(pane: pane.id.uuidString, url: "bend://chats")) }
}
