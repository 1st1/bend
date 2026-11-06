import Foundation
import SQLite3
import Testing
@testable import BrowseCore

private func historySQL(_ file: URL, _ sql: String) throws -> [[String]] {
    var db: OpaquePointer?
    guard sqlite3_open(file.path, &db) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw CocoaError(.fileReadCorruptFile) }
    defer { sqlite3_finalize(statement) }
    var result: [[String]] = []
    while true {
        switch sqlite3_step(statement) {
        case SQLITE_DONE: return result
        case SQLITE_ROW:
            result.append((0..<sqlite3_column_count(statement)).map { String(cString: sqlite3_column_text(statement, $0)) })
        default: throw CocoaError(.fileReadUnknown)
        }
    }
}

// @lat: [[tests#SQLite history transactions]]
@Test func sqliteHistoryTransactions() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendSQLite-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("History.db")
    let db = try HistoryDatabase(file: file)
    var history = BrowsingHistory()
    let date = Date(timeIntervalSince1970: 1793931234.1234567)
    history.record(url: "https://example.com/", title: "First", at: date)
    history.record(url: "https://example.com/", title: "Unicode café ' quote\0suffix", at: date.addingTimeInterval(60))
    history.recordChoice(url: "https://example.com/", query: "example", at: date)
    try db.save(history)
    #expect(try HistoryDatabase(file: file).load() == history)
    #expect(try historySQL(file, "SELECT count(*) FROM history_items") == [["1"]])
    #expect(try historySQL(file, "SELECT count(*) FROM history_visits") == [["2"]])
    #expect(try historySQL(file, "PRAGMA journal_mode") == [["wal"]])

    // A title change must update its row without reinserting or rewriting unrelated visits.
    _ = try historySQL(file, "CREATE TRIGGER forbid_visit_delete BEFORE DELETE ON history_visits BEGIN SELECT RAISE(ABORT, 'unexpected deletion'); END")
    _ = try historySQL(file, "CREATE TRIGGER forbid_old_update BEFORE UPDATE ON history_visits WHEN OLD.title = 'First' BEGIN SELECT RAISE(ABORT, 'unrelated update'); END")
    history.updateTitle("Updated", for: "https://example.com/")
    try db.save(history)
    #expect(try HistoryDatabase(file: file).load() == history)
    _ = try historySQL(file, "DROP TRIGGER forbid_visit_delete")
    _ = try historySQL(file, "DROP TRIGGER forbid_old_update")

    // Fail after a deletion and item insertion; both must roll back, and retry must work.
    _ = try historySQL(file, "CREATE TRIGGER reject_visit BEFORE INSERT ON history_visits BEGIN SELECT RAISE(ABORT, 'injected failure'); END")
    var changed = history
    changed.remove(url: "https://example.com/")
    changed.record(url: "https://other.example/", title: "Other", at: date)
    #expect(throws: (any Error).self) { try db.save(changed) }
    #expect(db.load() == history)
    #expect(try HistoryDatabase(file: file).load() == history)
    #expect(try historySQL(file, "SELECT count(*) FROM history_items") == [["1"]])
    _ = try historySQL(file, "DROP TRIGGER reject_visit")
    try db.save(changed)
    #expect(try HistoryDatabase(file: file).load() == changed)
    changed.clear()
    try db.save(changed)
    for table in ["history_items", "history_visits", "history_choices"] {
        #expect(try historySQL(file, "SELECT count(*) FROM \(table)") == [["0"]])
    }
}

// @lat: [[tests#JSON history migration]]
@Test func jsonHistoryMigration() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendMigration-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let legacy = root.appendingPathComponent("history.json")
    let file = root.appendingPathComponent("History.db")
    var history = BrowsingHistory()
    let date = Date()
    history.record(url: "https://example.com/", title: "Example", at: date)
    history.record(url: "https://example.com/deep", title: "Deep", at: date.addingTimeInterval(100))
    history.recordChoice(url: "https://example.com/deep", query: "ex", at: date)
    let original = try JSONEncoder().encode(history)
    try original.write(to: legacy)
    let database = try HistoryDatabase(file: file, legacyFile: legacy)
    #expect(database.load() == history)
    #expect(!FileManager.default.fileExists(atPath: legacy.path))
    #expect(try HistoryDatabase(file: file).load().suggestions(for: "ex", now: date) == history.suggestions(for: "ex", now: date))
    try database.save(BrowsingHistory())
    // A leftover pre-migration copy must not resurrect deleted visits.
    try original.write(to: legacy)
    #expect(try HistoryDatabase(file: file, legacyFile: legacy).load().visits.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: legacy.path))
    _ = try historySQL(file, "PRAGMA user_version = 99")
    #expect(throws: (any Error).self) { try HistoryDatabase(file: file) }
    #expect(try historySQL(file, "PRAGMA user_version") == [["99"]])
}

// @lat: [[tests#SQLite history retention]]
@Test func sqliteHistoryRetention() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendRetention-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("History.db")
    let database = try HistoryDatabase(file: file)
    let visits = (0..<BrowsingHistory.maximumVisits).map {
        HistoryVisit(id: UUID(), url: "https://example.com/\($0)", title: "Page", date: Date(timeIntervalSince1970: Double(20_000 - $0)))
    }
    var history = BrowsingHistory(visits: visits, choices: [])
    try database.save(history)
    history.record(url: "https://example.com/new", title: "Newest", at: Date(timeIntervalSince1970: 30_000))
    try database.save(history)
    #expect(try HistoryDatabase(file: file).load() == history)
    #expect(try historySQL(file, "SELECT count(*) FROM history_visits") == [["10000"]])
    #expect(try historySQL(file, "SELECT count(*) FROM history_items") == [["10000"]])
    #expect(try historySQL(file, "SELECT count(*) FROM history_items WHERE url = 'https://example.com/9999'") == [["0"]])
}
