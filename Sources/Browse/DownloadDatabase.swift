import Foundation
import SQLite3

struct DownloadRecord: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case downloading, cancelling, cancelled, completed, failed }
    var id = UUID()
    var name = "Download"
    var state = State.downloading
    var received: Int64 = 0
    var total: Int64 = 0
    var error: String?
    var fileURL: URL?
    var sourceURL: URL?
    var method = "GET"
    var directory: URL
}

// @lat: [[lat.md/architecture/downloads#Download database]]
final class DownloadDatabase {
    static let limit = 256
    private var connection: OpaquePointer?
    private var saved: [DownloadRecord] = []

    init(file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(file.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            let error = failure(); sqlite3_close(connection); connection = nil; throw error
        }
        do {
            sqlite3_busy_timeout(connection, 1_000)
            let version = try rows("PRAGMA user_version").first?.first
            guard version == "0" || version == "1" else { throw DatabaseError(message: "Unsupported download database version.") }
            if version == "0" {
                guard try rows("SELECT name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'").isEmpty else {
                    throw DatabaseError(message: "Unrecognized download database.")
                }
                try transaction {
                    try execute("CREATE TABLE downloads (sequence INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE, record TEXT NOT NULL)")
                    try execute("PRAGMA user_version = 1")
                }
            }
            saved = try rows("SELECT id, record FROM downloads ORDER BY sequence DESC").map { row in
                let record = try JSONDecoder().decode(DownloadRecord.self, from: Data(row[1].utf8))
                guard record.id.uuidString == row[0], record.directory.isFileURL,
                      record.fileURL == nil || record.fileURL?.isFileURL == true else { throw CocoaError(.fileReadCorruptFile) }
                return record
            }
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = FULL")
            try execute("PRAGMA secure_delete = ON")
            if saved.count > Self.limit { try save(Array(saved.prefix(Self.limit))) }
        } catch {
            sqlite3_close(connection); connection = nil; throw error
        }
    }

    deinit { sqlite3_close(connection) }
    func load() -> [DownloadRecord] { saved }

    func save(_ records: [DownloadRecord]) throws {
        let bounded = Array(records.prefix(Self.limit))
        let ids = Set(bounded.map(\.id))
        guard ids.count == bounded.count else { throw CocoaError(.fileWriteInvalidFileName) }
        let previous = Dictionary(uniqueKeysWithValues: saved.map { ($0.id, $0) })
        guard bounded != saved else { return }
        try transaction {
            for record in saved where !ids.contains(record.id) {
                try run("DELETE FROM downloads WHERE id = ?", [record.id.uuidString])
            }
            // Insert oldest first; updates retain their original sequence.
            for record in bounded.reversed() where previous[record.id] != record {
                let json = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
                try run("INSERT INTO downloads(id, record) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET record = excluded.record",
                        [record.id.uuidString, json])
            }
            try execute("DELETE FROM downloads WHERE sequence NOT IN (SELECT sequence FROM downloads ORDER BY sequence DESC LIMIT 256)")
        }
        saved = bounded
    }

    private struct DatabaseError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    private func failure() -> Error {
        DatabaseError(message: connection.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open download history.")
    }
    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try body(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement); throw failure()
        }
        return statement
    }
    private func run(_ sql: String, _ values: [String]) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            let status = value.withCString {
                sqlite3_bind_text(statement, Int32(index + 1), $0, Int32(value.utf8.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
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
                    guard let bytes = sqlite3_column_text(statement, column) else { return "" }
                    return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, column))), as: UTF8.self)
                })
            default: throw failure()
            }
        }
    }
}
