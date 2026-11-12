import Foundation
import SQLite3

// @lat: [[lat.md/architecture/history#History database]]
// One connection owned by the root BrowserStore, used on its main actor.
public final class HistoryDatabase {
    private var connection: OpaquePointer?
    private var saved = BrowsingHistory()

    private struct DatabaseError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    public init(file: URL, legacyFile: URL? = nil) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(file.path, &connection, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            let error = failure()
            sqlite3_close(connection)
            connection = nil
            throw error
        }
        do {
            sqlite3_busy_timeout(connection, 1_000)
            try execute("PRAGMA foreign_keys = ON")
            let version = try rows("PRAGMA user_version").first?.first
            guard version == "0" || version == "1" else {
                throw DatabaseError(message: "History database version is not supported.")
            }
            if version == "0" {
                // Never adopt an unrelated SQLite database or overwrite an unreadable JSON file.
                guard try rows("SELECT name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'").isEmpty else {
                    throw DatabaseError(message: "Unrecognized history database.")
                }
                var imported = BrowsingHistory()
                if let legacyFile, FileManager.default.fileExists(atPath: legacyFile.path) {
                    imported = try JSONDecoder().decode(BrowsingHistory.self, from: Data(contentsOf: legacyFile))
                    guard imported.isValid else { throw CocoaError(.fileReadCorruptFile) }
                }
                try transaction {
                    try execute("""
                        CREATE TABLE history_items (
                            id INTEGER PRIMARY KEY,
                            url TEXT NOT NULL UNIQUE
                        );
                        CREATE TABLE history_visits (
                            id TEXT PRIMARY KEY NOT NULL,
                            history_item INTEGER NOT NULL REFERENCES history_items(id) ON DELETE CASCADE,
                            title TEXT NOT NULL,
                            visit_time REAL NOT NULL
                        );
                        CREATE INDEX visits_by_item ON history_visits(history_item);
                        CREATE INDEX visits_by_time ON history_visits(visit_time DESC);
                        CREATE TABLE history_choices (
                            query TEXT NOT NULL,
                            history_item INTEGER NOT NULL REFERENCES history_items(id) ON DELETE CASCADE,
                            weight REAL NOT NULL CHECK(weight > 0),
                            choice_time REAL NOT NULL,
                            PRIMARY KEY(query, history_item)
                        );
                        CREATE INDEX choices_by_item ON history_choices(history_item);
                        """)
                    try writeChanges(imported)
                    try execute("PRAGMA user_version = 1")
                }
            }
            saved = try readHistory()
            // WAL allows readers during a write; FULL makes each committed transaction durable.
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = FULL")
            try execute("PRAGMA secure_delete = ON")
            // The committed schema version is the migration marker. A leftover JSON file
            // is never reimported, even after history is cleared.
            if let legacyFile { try? FileManager.default.removeItem(at: legacyFile) }
        } catch {
            sqlite3_close(connection)
            connection = nil
            throw error
        }
    }

    deinit { sqlite3_close(connection) }

    public func load() -> BrowsingHistory { saved }

    public func save(_ history: BrowsingHistory) throws {
        guard history.isValid else { throw DatabaseError(message: "Invalid history data.") }
        try transaction { try writeChanges(history) }
        saved = history
    }

    private func writeChanges(_ history: BrowsingHistory) throws {
        let previousVisits = Dictionary(uniqueKeysWithValues: saved.visits.map { ($0.id, $0) })
        let visitIDs = Set(history.visits.map(\.id))
        for visit in saved.visits where !visitIDs.contains(visit.id) {
            try run("DELETE FROM history_visits WHERE id = ?", [.text(visit.id.uuidString)])
        }
        let previousChoices = Dictionary(uniqueKeysWithValues: saved.choices.map { ([$0.query, $0.url], $0) })
        let choiceKeys = Set(history.choices.map { [$0.query, $0.url] })
        for choice in saved.choices where !choiceKeys.contains([choice.query, choice.url]) {
            try run("DELETE FROM history_choices WHERE query = ? AND history_item = (SELECT id FROM history_items WHERE url = ?)",
                    [.text(choice.query), .text(choice.url)])
        }
        for visit in history.visits where previousVisits[visit.id] != visit {
            try insertItem(visit.url)
            try run("""
                INSERT INTO history_visits(id, history_item, title, visit_time)
                VALUES (?, (SELECT id FROM history_items WHERE url = ?), ?, ?)
                ON CONFLICT(id) DO UPDATE SET title = excluded.title, visit_time = excluded.visit_time
                """, [.text(visit.id.uuidString), .text(visit.url), .text(visit.title), .number(visit.date.timeIntervalSinceReferenceDate)])
        }
        for choice in history.choices where previousChoices[[choice.query, choice.url]] != choice {
            try insertItem(choice.url)
            try run("""
                INSERT INTO history_choices(query, history_item, weight, choice_time)
                VALUES (?, (SELECT id FROM history_items WHERE url = ?), ?, ?)
                ON CONFLICT(query, history_item) DO UPDATE SET weight = excluded.weight, choice_time = excluded.choice_time
                """, [.text(choice.query), .text(choice.url), .number(choice.weight), .number(choice.date.timeIntervalSinceReferenceDate)])
        }
        try execute("""
            DELETE FROM history_items WHERE NOT EXISTS (SELECT 1 FROM history_visits WHERE history_item = history_items.id)
                AND NOT EXISTS (SELECT 1 FROM history_choices WHERE history_item = history_items.id)
            """)
    }

    private func insertItem(_ url: String) throws {
        try run("INSERT INTO history_items(url) VALUES (?) ON CONFLICT(url) DO NOTHING", [.text(url)])
    }

    // Like Foundation and Safari history, timestamps use seconds since January 1, 2001.
    // This also preserves Date precision without an epoch-conversion round trip.
    private func readHistory() throws -> BrowsingHistory {
        guard try rows("PRAGMA quick_check") == [["ok"]], try rows("PRAGMA foreign_key_check").isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let visits = try rows("""
            SELECT v.id, i.url, v.title, v.visit_time FROM history_visits v
            JOIN history_items i ON i.id = v.history_item ORDER BY v.visit_time DESC, v.rowid
            """).map { row -> HistoryVisit in
                guard let id = UUID(uuidString: row[0]), let time = Double(row[3]) else { throw CocoaError(.fileReadCorruptFile) }
                return HistoryVisit(id: id, url: row[1], title: row[2], date: Date(timeIntervalSinceReferenceDate: time))
            }
        let choices = try rows("""
            SELECT c.query, i.url, c.weight, c.choice_time FROM history_choices c
            JOIN history_items i ON i.id = c.history_item ORDER BY c.choice_time DESC, c.rowid
            """).map { row -> HistoryChoice in
                guard let weight = Double(row[2]), let time = Double(row[3]) else { throw CocoaError(.fileReadCorruptFile) }
                return HistoryChoice(query: row[0], url: row[1], weight: weight, date: Date(timeIntervalSinceReferenceDate: time))
            }
        let history = BrowsingHistory(visits: visits, choices: choices)
        guard history.isValid else { throw CocoaError(.fileReadCorruptFile) }
        return history
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try body(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }

    private func failure() -> DatabaseError {
        DatabaseError(message: connection.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open history database.")
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
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
                // An explicit byte length preserves embedded NULs in page titles.
                status = string.withCString { sqlite3_bind_text(statement, index, $0, Int32(string.utf8.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            case .number(let number): status = sqlite3_bind_double(statement, index, number)
            }
            guard status == SQLITE_OK else { throw failure() }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw failure()
        }
        return statement
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
