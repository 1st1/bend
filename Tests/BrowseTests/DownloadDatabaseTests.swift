import Foundation
import AppKit
import SwiftUI
import SQLite3
import Testing
@testable import Browse

// @lat: [[lat.md/tests/downloads-tests#Download database retention and transactions]]
@Test func downloadDatabaseRetention() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendDownloadDB-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("Downloads.db")
    let database = try DownloadDatabase(file: file)
    var records = (0..<256).map { index in
        DownloadRecord(name: "file \(index).txt", state: .completed, received: 25, total: 25,
                       fileURL: root.appendingPathComponent("file \(index).txt"), directory: root)
    }
    let oldest = records.last!
    try Data("preserved".utf8).write(to: oldest.fileURL!)
    try database.save(records)
    #expect(try DownloadDatabase(file: file).load() == records)
    records.insert(DownloadRecord(name: "new.txt", directory: root), at: 0)
    try database.save(records)
    records.removeLast()
    #expect(database.load().count == 256)
    #expect(try DownloadDatabase(file: file).load() == records)
    #expect(try String(contentsOf: oldest.fileURL!, encoding: .utf8) == "preserved")

    var connection: OpaquePointer?
    #expect(sqlite3_open(file.path, &connection) == SQLITE_OK)
    defer { sqlite3_close(connection) }
    #expect(sqlite3_exec(connection, "CREATE TRIGGER reject_download BEFORE INSERT ON downloads BEGIN SELECT RAISE(ABORT, 'injected failure'); END", nil, nil, nil) == SQLITE_OK)
    var changed = records
    changed.removeLast()
    changed[0].name = "changed.txt"
    #expect(throws: (any Error).self) { try database.save(changed) }
    #expect(database.load() == records)
    #expect(try DownloadDatabase(file: file).load() == records)
    #expect(sqlite3_exec(connection, "DROP TRIGGER reject_download", nil, nil, nil) == SQLITE_OK)
    try database.save(changed)
    #expect(try DownloadDatabase(file: file).load() == changed)
    try database.save([])
    #expect(try DownloadDatabase(file: file).load().isEmpty)
    #expect(FileManager.default.fileExists(atPath: oldest.fileURL!.path))
}

// @lat: [[lat.md/tests/downloads-tests#Download history recovery]]
@Test @MainActor func downloadHistoryRecovery() throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendDownloadRecovery-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("Downloads.db")
    let corrupt = Data("unreadable history".utf8)
    try corrupt.write(to: file)
    let manager = BrowserDownloads(directory: root, databaseFile: file)
    #expect(manager.persistenceError != nil)
    manager.clearFinished()
    #expect(try Data(contentsOf: file) == corrupt)
    try FileManager.default.removeItem(at: file)
    manager.retryPersistence()
    #expect(manager.persistenceError == nil)
    manager.shutdown()
    let database = try DownloadDatabase(file: file)
    let post = DownloadRecord(name: "post.bin", state: .downloading,
                              sourceURL: URL(string: "https://example.com/post"), method: "POST", directory: root)
    let get = DownloadRecord(name: "get.bin", state: .cancelling,
                             sourceURL: URL(string: "https://example.com/get"), directory: root)
    try database.save([post, get])
    let restored = BrowserDownloads(directory: root, databaseFile: file)
    defer { restored.shutdown() }
    #expect(restored.items.count == 2)
    #expect(restored.items.allSatisfy { $0.state == .failed && $0.error?.contains("Interrupted") == true })
    #expect(!restored.items[0].canRetry && restored.items[1].canRetry)
    #expect(restored.activeCount == 0 && restored.progressFraction == nil)
}

// @lat: [[lat.md/tests/downloads-tests#Combined download progress]]
@Test @MainActor func combinedDownloadProgress() async throws {
    #expect(BrowserDownloads.combinedProgress([]) == nil)
    #expect(BrowserDownloads.combinedProgress([(50, 100), (25, 100)]) == 0.375)
    #expect(BrowserDownloads.combinedProgress([(100, 100), (0, 300)]) == 0.25)
    #expect(BrowserDownloads.combinedProgress([(50, 100), (25, 0)]) == nil)
    #expect(BrowserDownloads.combinedProgress([(-10, 100), (200, 100)]) == 0.5)
    #expect(BrowserDownloads.combinedProgress([(Int64.max, Int64.max), (Int64.max, Int64.max)]) == 1)
    if let path = ProcessInfo.processInfo.environment["BEND_DOWNLOAD_PROGRESS_SNAPSHOT"] {
        let preview = NSHostingView(rootView: HStack(spacing: 20) {
            DownloadProgressIcon(active: false, fraction: nil)
            DownloadProgressIcon(active: true, fraction: 0.25)
            DownloadProgressIcon(active: true, fraction: 0.7)
            DownloadProgressIcon(active: true, fraction: nil)
        }.font(.system(size: 14)).padding(20).preferredColorScheme(.dark))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 170, height: 56),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = preview; window.orderFront(nil)
        defer { window.close() }
        for _ in 0..<5 { preview.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(40)) }
        let bitmap = try #require(preview.bitmapImageRepForCachingDisplay(in: preview.bounds))
        preview.cacheDisplay(in: preview.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
