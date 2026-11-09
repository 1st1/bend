import AppKit
import CryptoKit
import Testing
import WebKit
@testable import Browse

// @lat: [[tests#Extension update metadata]]
@Test func extensionUpdateMetadata() throws {
    let hash = String(repeating: "a", count: 64)
    let mozilla = ExtensionUpdateSource.mozilla(slug: "darkreader")
    var json: [String: Any] = ["guid": "addon@darkreader.org", "status": "public", "current_version": [
        "version": "4.9.135", "file": ["status": "public", "size": 900000, "hash": "sha256:" + hash,
            "url": "https://addons.mozilla.org/firefox/downloads/file/5216111/darkreader-4.9.135.xpi"]]]
    func parse(_ object: [String: Any]) throws -> CatalogDownload {
        try mozilla.parse(JSONSerialization.data(withJSONObject: object), packageIdentifier: "gecko:addon@darkreader.org")
    }
    #expect(try parse(json).version == "4.9.135")
    json["guid"] = "wrong@example.test"
    #expect(throws: CatalogError.self) { try parse(json) }
    json["guid"] = "addon@darkreader.org"
    json["status"] = "disabled"
    #expect(throws: CatalogError.self) { try parse(json) }
    json["status"] = "public"
    for invalidFile in [
        ["status": "public", "size": 10, "hash": "sha256:" + hash, "url": "https://evil.example/package.xpi"],
        ["status": "disabled", "size": 10, "hash": "sha256:" + hash, "url": "https://addons.mozilla.org/firefox/downloads/file/1/a.xpi"],
        ["status": "public", "size": 10, "hash": "sha256:bad", "url": "https://addons.mozilla.org/firefox/downloads/file/1/a.xpi"],
        ["status": "public", "size": CatalogDownload.maximumBytes + 1, "hash": "sha256:" + hash, "url": "https://addons.mozilla.org/firefox/downloads/file/1/a.xpi"]
    ] {
        json["current_version"] = ["version": "4.9.135", "file": invalidFile]
        #expect(throws: CatalogError.self) { try parse(json) }
    }
    let safari = CatalogExtension.curated[0]
    let releaseURL = URL(string: "https://github.com/uBlockOrigin/uBOL-home/releases/tag/\(safari.download.version)")!
    #expect(try GitHubReleasePage.version(from: releaseURL) == safari.download.version)
    let filename = safari.download.url.lastPathComponent
    let row = """
    <li><a class="asset" href="\(safari.download.url.path)"><span>\(filename)</span></a>
    <span class="Truncate-text">sha256:\(safari.download.sha256)</span></li>
    """
    func parseAssets(_ html: String) throws -> CatalogDownload {
        try GitHubReleasePage.download(from: Data(html.utf8), version: safari.download.version,
                                       packageIdentifier: safari.packageIdentifier)
    }
    let parsed = try parseAssets("<ul>" + row + "</ul>")
    #expect(parsed.sha256 == safari.download.sha256)
    #expect(parsed.url == safari.download.url)
    for invalid in [
        row + row,
        row.replacingOccurrences(of: "sha256:", with: "sha512:"),
        row.replacingOccurrences(of: safari.download.sha256, with: "bad"),
        row.replacingOccurrences(of: "</li>", with: "<span>sha256:" + hash + "</span></li>"),
        row.replacingOccurrences(of: safari.download.url.path, with: "https://evil.example/package.zip"),
        row.replacingOccurrences(of: ".safari.zip", with: ".chromium.zip"),
        "<li><a href='\(safari.download.url.path)'>Safari</a></li><li><span>sha256:\(safari.download.sha256)</span></li>",
        "<html>Markup changed</html>"
    ] {
        #expect(throws: (any Error).self) { try parseAssets(invalid) }
    }
    for address in ["https://evil.example/uBlockOrigin/uBOL-home/releases/tag/1.0",
                    "https://github.com/other/repo/releases/tag/1.0",
                    "https://github.com/uBlockOrigin/uBOL-home/releases/tag/1.0-beta",
                    "https://github.com/uBlockOrigin/uBOL-home/releases/tag/1.0?unexpected=true"] {
        #expect(throws: CatalogError.self) { try GitHubReleasePage.version(from: URL(string: address)!) }
    }
    #expect(ExtensionVersion.isNewer("1.10", than: "1.9"))
    #expect(!ExtensionVersion.isNewer("1.0.0", than: "1.0"))
    #expect(!ExtensionVersion.isNewer("2.0beta", than: "1.0"))
    #expect(!ExtensionVersion.isNewer("4.9.134", than: "4.9.135"))
    #expect(!ExtensionVersion.isNewer("1..1", than: "1.0"))
}

// @lat: [[tests#Automatic extension updates]]
@Test @MainActor func automaticExtensionUpdates() async throws {
    guard #available(macOS 15.4, *) else { return }
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendUpdateTest-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try extensionFixture(at: root)
    let manifestURL = source.appendingPathComponent("manifest.json")
    var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
    manifest["browser_specific_settings"] = ["gecko": ["id": "addon@darkreader.org"]]
    try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
    let manager = ExtensionManager(root: root.appendingPathComponent("installed"), persistent: false)
    try await manager.importExtension(from: source)
    let record = try #require(manager.records.first)
    try await manager.enable(true, id: record.id) { _, _ in true }
    let origin = manager.contexts[record.id]?.baseURL
    let updater = manager.updates
    defer { updater.stop() }
    var metadataCalls = 0
    var downloadCalls = 0
    func archive(version: String) throws -> (CatalogDownload, Data) {
        manifest["version"] = version
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        let url = root.appendingPathComponent("\(version).xpi")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-q", "-r", url.path, "."]; zip.currentDirectoryURL = source
        try zip.run(); zip.waitUntilExit()
        let data = try Data(contentsOf: url)
        return (CatalogDownload(version: version, url: URL(string: "https://addons.mozilla.org/firefox/downloads/file/1/update.xpi")!,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()), data)
    }
    var (download, data) = try archive(version: "2.0")
    updater.fetchLatest = { _ in
        metadataCalls += 1
        #expect(!manager.busy)
        await Task.yield()
        return download
    }
    updater.fetchPackage = { _ in downloadCalls += 1; return data }
    updater.automaticallyInstall = false
    updater.check(); updater.check()
    await updater.task?.value
    #expect(metadataCalls == 1)
    #expect(downloadCalls == 0)
    #expect(updater.candidates[record.id]?.download.version == "2.0")
    #expect(manager.contexts[record.id]?.webExtension.version == "1.0")
    let pending = ExtensionUpdater(manager: manager)
    pending.fetchLatest = { _ in metadataCalls += 1; return download }
    pending.start(); await pending.task?.value; pending.stop()
    #expect(metadataCalls == 1)
    #expect(pending.candidates[record.id]?.download.version == "2.0")
    updater.update(record.id)
    await updater.task?.value
    #expect(downloadCalls == 1)
    #expect(manager.contexts[record.id]?.webExtension.version == "2.0")
    #expect(manager.contexts[record.id]?.baseURL == origin)
    #expect(manager.isEnabled(record.id))
    #expect(updater.candidates.isEmpty)
    updater.checkIfDue(now: try #require(updater.lastChecked).addingTimeInterval(60))
    #expect(updater.task == nil)
    updater.checkIfDue(now: try #require(updater.lastChecked).addingTimeInterval(ExtensionUpdater.checkInterval + 1))
    await updater.task?.value
    #expect(metadataCalls == 2)
    #expect(downloadCalls == 1)
    let restored = ExtensionUpdater(manager: manager)
    #expect(!restored.automaticallyInstall)
    #expect(restored.lastChecked != nil)
    restored.fetchLatest = { _ in
        metadataCalls += 1
        return download
    }
    restored.start() // Reuse persisted metadata and reconstruct the visible status.
    await restored.task?.value
    #expect(metadataCalls == 2)
    #expect(restored.messages[record.id] == "Up to date.")
    restored.stop()
    restored.check() // An explicit check bypasses the cache.
    await restored.task?.value
    #expect(metadataCalls == 3)
    #expect(!ExtensionUpdater.CachedCheck(checkedAt: Date().addingTimeInterval(60), download: download, error: nil).isFresh(at: Date()))
    restored.fetchLatest = { _ in throw UpdateServiceError.rateLimited(service: "Mozilla") }
    restored.check(); await restored.task?.value
    let failed = ExtensionUpdater(manager: manager)
    failed.fetchLatest = { _ in metadataCalls += 1; return download }
    failed.start(); await failed.task?.value; failed.stop()
    #expect(metadataCalls == 3)
    #expect(failed.messages[record.id]?.contains("Mozilla") == true)
    updater.automaticallyInstall = true
    // A metadata/package version mismatch must leave the running revision intact.
    let currentSource = manager.records[0].source
    download = CatalogDownload(version: "3.0", url: download.url, sha256: download.sha256)
    updater.check(); await updater.task?.value
    #expect(manager.records[0].source == currentSource)
    #expect(manager.isEnabled(record.id))
    #expect(updater.messages[record.id]?.contains("unexpected version") == true)
    manifest["host_permissions"] = ["http://127.0.0.1/*", "https://new.example/*"]
    (download, data) = try archive(version: "3.0")
    updater.check(); await updater.task?.value
    #expect(manager.contexts[record.id]?.webExtension.version == "3.0")
    #expect(!manager.isEnabled(record.id))
    #expect(manager.failures[record.id] != nil)
    #expect(manager.contexts[record.id]?.hasAccess(to: URL(string: "https://new.example/")!) == false)
    try await manager.enable(false, id: record.id) { _, _ in true }
    (download, data) = try archive(version: "4.0")
    updater.check(); await updater.task?.value
    #expect(manager.contexts[record.id]?.webExtension.version == "4.0")
    #expect(!manager.records[0].enabled)
    #expect(!manager.isEnabled(record.id))
    let beforeFailure = manager.records[0].source
    (download, data) = try archive(version: "5.0")
    updater.fetchPackage = { _ in throw CatalogError.checksumMismatch }
    updater.check(); await updater.task?.value
    #expect(manager.records[0].source == beforeFailure)
    #expect(updater.candidates[record.id] != nil)
    #expect(updater.messages[record.id]?.contains("checksum") == true)
    // A package removed while its update downloads must never be reinstalled.
    updater.fetchPackage = { _ in try await manager.uninstall(record.id); return data }
    updater.update(record.id); await updater.task?.value
    #expect(manager.records.isEmpty)
    #expect(updater.messages[record.id]?.contains("changed") == true)
}

// @lat: [[tests#Extension update service smoke test]]
@Test(arguments: ["ublock-lite", "1password", "dark-reader"])
func extensionUpdateServiceSmoke(entryID: String) async throws {
    guard let selection = ProcessInfo.processInfo.environment["BROWSE_TEST_EXTENSION_UPDATES"],
          selection == "1" || selection.split(separator: ",").contains(Substring(entryID)) else { return }
    let entry = try #require(CatalogExtension.curated.first { $0.id == entryID })
    let download = try await entry.updateSource.latest(packageIdentifier: entry.packageIdentifier)
    #expect(ExtensionVersion.components(download.version) != nil)
    let data = try await download.fetch()
    #expect(!data.isEmpty)
    print("EXTENSION_UPDATE", entryID, download.version, download.sha256)
}
