import Foundation
import Testing
import SQLite3
@testable import BrowseCore

// @lat: [[lat.md/tests/settings-tests#Settings tests#Website permission persistence]]
@Test func websitePermissionPersistence() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("settings.sqlite")
    let secure = try #require(WebsitePermission.origin(for: URL(string: "https://EXAMPLE.com/path")!))
    #expect(secure == "https://example.com:443")
    #expect(WebsitePermission.origin(for: URL(string: "https://example.com:443/other")!) == secure)
    #expect(WebsitePermission.origin(for: URL(string: "http://example.com")!) != secure)
    #expect(WebsitePermission.origin(for: URL(string: "https://example.com:8443")!) != secure)
    #expect(WebsitePermission.origin(for: URL(string: "https://sub.example.com")!) != secure)
    #expect(WebsitePermission.origin(for: URL(string: "file:///test")!) == nil)
    do {
        let database = try WebsiteSettingsDatabase(file: file)
        var settings = database.load()
        settings.defaultZoom = 1.25
        settings.blockedPermissions[secure] = [.camera, .location]
        settings.allowedPermissions[secure] = [.microphone]
        try database.save(settings)
    }
    let database = try WebsiteSettingsDatabase(file: file)
    var settings = database.load()
    #expect(settings.defaultZoom == 1.25)
    #expect(settings.blockedPermissions[secure] == [.camera, .location])
    #expect(settings.permission(.microphone, for: secure) == .allow)
    settings.allowedPermissions.removeAll()
    settings.blockedPermissions.removeAll()
    try database.save(settings)
    #expect(try WebsiteSettingsDatabase(file: file).load().blockedPermissions.isEmpty)
    settings.blockedPermissions["https://example.com"] = [.camera]
    #expect(!settings.isValid)

    let legacy = root.appendingPathComponent("version4.sqlite")
    do {
        let old = try WebsiteSettingsDatabase(file: legacy)
        var values = old.load()
        values.blockedPermissions[secure] = [.camera]
        try old.save(values)
    }
    var connection: OpaquePointer?
    #expect(sqlite3_open(legacy.path, &connection) == SQLITE_OK)
    #expect(sqlite3_exec(connection, """
        DROP TABLE http_exceptions;
        ALTER TABLE website_permissions DROP COLUMN decision;
        PRAGMA user_version = 4;
        """, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(connection)
    let migrated = try WebsiteSettingsDatabase(file: legacy).load()
    #expect(migrated.permission(.camera, for: secure) == .block)
    #expect(migrated.allowedPermissions.isEmpty)
    #expect(migrated.allowedHTTPOrigins.isEmpty)
}
