import Foundation
import SQLite3
import Testing
@testable import BrowseCore

// @lat: [[tests#Website setting identity]]
@Test func websiteSettingIdentity() throws {
    var settings = WebsiteSettings()
    settings.defaultZoom = 1.1
    settings.zoomByHost["example.com"] = 1.5
    for address in ["https://EXAMPLE.com/a", "http://example.com:8080/b", "https://example.com./"] {
        #expect(settings.zoom(for: try #require(URL(string: address))) == 1.5)
    }
    for address in ["https://www.example.com/", "https://news.example.com/", "https://other.test/"] {
        #expect(settings.zoom(for: try #require(URL(string: address))) == 1.1)
    }
    for address in ["browse://start", "about:blank", "file:///tmp/test", "webkit-extension://example.com/"] {
        let url = try #require(URL(string: address))
        #expect(WebsiteSettings.hostname(for: url) == nil)
        #expect(settings.zoom(for: url) == 1)
    }
    #expect(WebsiteSettings.hostname(for: try #require(URL(string: "https://bücher.example/"))) == "xn--bcher-kva.example")
    #expect(WebsiteSettings.hostname(for: try #require(URL(string: "http://[::1]:8080/"))) == "[::1]")
    #expect(settings.isValid)
    for invalid in [Double.nan, .infinity, -.infinity, 0, 5.1] {
        settings.defaultZoom = invalid
        #expect(!settings.isValid)
    }
    settings.defaultZoom = 1
    settings.zoomByHost["example.com/path"] = 1.2
    #expect(!settings.isValid)
}

private func websiteSQL(_ file: URL, _ sql: String) throws {
    var db: OpaquePointer?
    guard sqlite3_open(file.path, &db) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
    defer { sqlite3_close(db) }
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileReadCorruptFile) }
}

// @lat: [[tests#Website settings transactions]]
@Test func websiteSettingsTransactions() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendWebsiteDB-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("WebsiteSettings.db")
    let database = try WebsiteSettingsDatabase(file: file)
    var settings = WebsiteSettings()
    settings.defaultZoom = 1.1
    settings.zoomByHost = ["example.com": 1.5, "other.test": 0.9]
    try database.save(settings)
    #expect(try WebsiteSettingsDatabase(file: file).load() == settings)
    // Failure after changing the default and deleting an override rolls back both.
    try websiteSQL(file, "CREATE TRIGGER reject_insert BEFORE INSERT ON website_settings BEGIN SELECT RAISE(ABORT, 'injected failure'); END")
    var changed = settings
    changed.defaultZoom = 1.25
    changed.zoomByHost.removeValue(forKey: "example.com")
    changed.zoomByHost["new.test"] = 2
    #expect(throws: (any Error).self) { try database.save(changed) }
    #expect(database.load() == settings)
    #expect(try WebsiteSettingsDatabase(file: file).load() == settings)
    try websiteSQL(file, "DROP TRIGGER reject_insert")
    try database.save(changed)
    #expect(try WebsiteSettingsDatabase(file: file).load() == changed)
    changed.zoomByHost.removeAll()
    try database.save(changed)
    #expect(try WebsiteSettingsDatabase(file: file).load() == changed)
    var invalid = changed
    invalid.defaultZoom = .nan
    #expect(throws: (any Error).self) { try database.save(invalid) }
    #expect(database.load() == changed)
}

// @lat: [[tests#Website settings storage protection]]
@Test func websiteSettingsStorageProtection() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendWebsiteProtection-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let corrupt = root.appendingPathComponent("corrupt.db")
    let original = Data("not a database".utf8)
    try original.write(to: corrupt)
    #expect(throws: (any Error).self) { try WebsiteSettingsDatabase(file: corrupt) }
    #expect(try Data(contentsOf: corrupt) == original)
    let unrelated = root.appendingPathComponent("unrelated.db")
    try websiteSQL(unrelated, "CREATE TABLE unrelated(value TEXT)")
    #expect(throws: (any Error).self) { try WebsiteSettingsDatabase(file: unrelated) }
    let future = root.appendingPathComponent("future.db")
    try websiteSQL(future, "PRAGMA user_version = 99")
    #expect(throws: (any Error).self) { try WebsiteSettingsDatabase(file: future) }
}
