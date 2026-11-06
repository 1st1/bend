import Foundation
import SQLite3

// @lat: [[architecture#Website settings database]]
public final class WebsiteSettingsDatabase {
    private var connection: OpaquePointer?
    private var saved = WebsiteSettings()

    private struct DatabaseError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    public init(file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(file.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            let error = failure()
            sqlite3_close(connection)
            connection = nil
            throw error
        }
        do {
            sqlite3_busy_timeout(connection, 1_000)
            let version = try rows("PRAGMA user_version").first?.first
            guard version == "0" || version == "1" else {
                throw DatabaseError(message: "Website settings database version is not supported.")
            }
            if version == "0" {
                guard try rows("SELECT name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'").isEmpty else {
                    throw DatabaseError(message: "Unrecognized website settings database.")
                }
                try transaction {
                    try execute("""
                        CREATE TABLE defaults (
                            id INTEGER PRIMARY KEY CHECK(id = 1),
                            page_zoom REAL NOT NULL CHECK(page_zoom BETWEEN 0.25 AND 5)
                        );
                        INSERT INTO defaults VALUES (1, 1);
                        CREATE TABLE website_settings (
                            hostname TEXT PRIMARY KEY NOT NULL,
                            page_zoom REAL NOT NULL CHECK(page_zoom BETWEEN 0.25 AND 5)
                        );
                        PRAGMA user_version = 1;
                        """)
                }
            }
            guard try rows("PRAGMA quick_check") == [["ok"]] else { throw CocoaError(.fileReadCorruptFile) }
            let defaults = try rows("SELECT page_zoom FROM defaults WHERE id = 1")
            guard defaults.count == 1, let zoom = defaults.first?.first.flatMap(Double.init) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            saved.defaultZoom = zoom
            for row in try rows("SELECT hostname, page_zoom FROM website_settings") {
                guard let zoom = Double(row[1]) else { throw CocoaError(.fileReadCorruptFile) }
                saved.zoomByHost[row[0]] = zoom
            }
            guard saved.isValid else { throw CocoaError(.fileReadCorruptFile) }
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = FULL")
            try execute("PRAGMA secure_delete = ON")
        } catch {
            sqlite3_close(connection)
            connection = nil
            throw error
        }
    }

    deinit { sqlite3_close(connection) }

    public func load() -> WebsiteSettings { saved }

    public func save(_ settings: WebsiteSettings) throws {
        guard settings.isValid else { throw DatabaseError(message: "Invalid website zoom settings.") }
        guard settings != saved else { return }
        try transaction {
            if settings.defaultZoom != saved.defaultZoom {
                try run("UPDATE defaults SET page_zoom = ? WHERE id = 1", [.number(settings.defaultZoom)])
            }
            for host in saved.zoomByHost.keys where settings.zoomByHost[host] == nil {
                try run("DELETE FROM website_settings WHERE hostname = ?", [.text(host)])
            }
            for (host, zoom) in settings.zoomByHost where saved.zoomByHost[host] != zoom {
                try run("""
                    INSERT INTO website_settings(hostname, page_zoom) VALUES (?, ?)
                    ON CONFLICT(hostname) DO UPDATE SET page_zoom = excluded.page_zoom
                    """, [.text(host), .number(zoom)])
            }
        }
        saved = settings
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try body(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }

    private func failure() -> DatabaseError {
        DatabaseError(message: connection.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open website settings database.")
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw failure()
        }
        return statement
    }

    private enum Value { case text(String), number(Double) }

    private func run(_ sql: String, _ values: [Value]) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case .text(let string):
                status = string.withCString { sqlite3_bind_text(statement, index, $0, Int32(string.utf8.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            case .number(let number): status = sqlite3_bind_double(statement, index, number)
            }
            guard status == SQLITE_OK else { throw failure() }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    private func rows(_ sql: String) throws -> [[String]] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        var result: [[String]] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_DONE: return result
            case SQLITE_ROW:
                result.append((0..<sqlite3_column_count(statement)).map { column in
                    if sqlite3_column_type(statement, column) == SQLITE_FLOAT { return String(sqlite3_column_double(statement, column)) }
                    guard let bytes = sqlite3_column_text(statement, column) else { return "" }
                    return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, column))), as: UTF8.self)
                })
            default: throw failure()
            }
        }
    }
}
