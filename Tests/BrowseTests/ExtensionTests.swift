import AppKit
import CryptoKit
import Network
import Testing
import WebKit
@testable import Browse

@MainActor
private func extensionFixture(at root: URL) throws -> URL {
    let source = root.appendingPathComponent("fixture", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try Data(#"""
    {"manifest_version":3,"name":"Browse Test Extension","version":"1.0",
     "browser_specific_settings":{"gecko":{"id":"browse-fixture@example.test"}},
     "permissions":["storage","tabs","declarativeNetRequest"],"host_permissions":["http://127.0.0.1/*"],
     "content_security_policy":{"extension_pages":"script-src 'self' 'wasm-unsafe-eval'; object-src 'self'"},
     "content_scripts":[{"matches":["http://127.0.0.1/*"],"js":["content.js"],"run_at":"document_end"}],
     "declarative_net_request":{"rule_resources":[{"id":"rules","enabled":true,"path":"rules.json"}]},
     "action":{"default_popup":"popup.html"},"options_ui":{"page":"options.html"}}
    """#.utf8).write(to: source.appendingPathComponent("manifest.json"))
    try Data("document.body.dataset.browseExtension = 'active';".utf8).write(to: source.appendingPathComponent("content.js"))
    try Data(#"[{"id":1,"priority":1,"action":{"type":"block"},"condition":{"urlFilter":"/blocked.js","resourceTypes":["script"]}}]"#.utf8)
        .write(to: source.appendingPathComponent("rules.json"))
    try Data("<body>Popup fixture</body>".utf8).write(to: source.appendingPathComponent("popup.html"))
    try Data("<body>Options fixture</body>".utf8).write(to: source.appendingPathComponent("options.html"))
    return source
}

// @lat: [[tests#Extension lifecycle and permissions]]
@Test @MainActor func extensionLifecycle() async throws {
    guard #available(macOS 15.4, *) else { return }
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseExtensions-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try extensionFixture(at: root)
    let manager = ExtensionManager(root: root.appendingPathComponent("installed"), persistent: false)
    try await manager.importExtension(from: source)
    let record = try #require(manager.records.first)
    #expect(record.source != source)
    #expect(!record.enabled)
    #expect(!manager.isEnabled(record.id))
    try await manager.enable(true, id: record.id) { _, requested in
        #expect(requested.contains("http://127.0.0.1/*"))
        return false
    }
    #expect(!manager.isEnabled(record.id))
    try await manager.enable(true, id: record.id) { _, _ in true }
    #expect(manager.isEnabled(record.id))
    #expect(manager.records[0].enabled)
    let context = try #require(manager.contexts[record.id])
    #expect(context.hasPermission(.init(rawValue: "storage")))
    #expect(context.hasAccess(to: URL(string: "http://127.0.0.1/test")!))
    #expect(!context.hasAccess(to: URL(string: "https://unrelated.example/")!))
    let baseURL = context.baseURL
    try await manager.enable(false, id: record.id) { _, _ in true }
    #expect(!manager.isEnabled(record.id))
    let restored = ExtensionManager(root: manager.root, persistent: false)
    restored.start()
    await restored.restorationTask?.value
    #expect(restored.records[0].permissions.contains("storage"))
    #expect(restored.contexts[record.id]?.baseURL == baseURL)
    #expect(!restored.isEnabled(record.id))
}

// @lat: [[tests#Extension content injection and blocking]]
@Test @MainActor func extensionContentAndBlocking() async throws {
    guard #available(macOS 15.4, *) else { return }
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseExtensionRuntime-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try extensionFixture(at: root)
    let server = try await ExtensionHTTPFixture.start()
    defer { server.listener.cancel() }
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    let manager = store.extensions
    let initialPaneCount = store.session.workspaces.flatMap(\.tabs).flatMap(\.pages).count
    try await manager.importExtension(from: source)
    let id = try #require(manager.records.first?.id)
    try await manager.enable(true, id: id) { _, _ in true }
    let page = store.selectedTab.pages[0]
    let pageController = store.controller(for: page)
    let web = pageController.webView
    let navigation = ExtensionTestNavigation()
    web.navigationDelegate = navigation
    let url = URL(string: "http://127.0.0.1:\(server.port)/")!
    try await navigation.load(web, url: url)
    #expect(try await web.evaluateJavaScript("document.body.dataset.browseExtension") as? String == "active")
    #expect(try await web.evaluateJavaScript("window.blockedScriptRan === true") as? Bool == false)
    let context = try #require(manager.contexts[id])
    #expect(manager.window.tabs(for: context).count == initialPaneCount)
    #expect(manager.window.activeTab(for: context) === manager.tabs[page.id])
    #expect(manager.tabs[page.id]?.webView(for: context) === web)
    store.split(.horizontal)
    #expect(manager.window.tabs(for: context).count == initialPaneCount + 1)
    #expect(manager.window.activeTab(for: context) === manager.tabs[store.selectedTab.focusedPane])
    store.closePage(page.id)
    #expect(manager.tabs[page.id] == nil)
    try await manager.enable(false, id: id) { _, _ in true }
    try await navigation.load(web, url: url)
    #expect(try await web.evaluateJavaScript("document.body.dataset.browseExtension || ''") as? String == "")
    #expect(try await web.evaluateJavaScript("window.blockedScriptRan === true") as? Bool == true)
}

// @lat: [[tests#Extension update permissions and resource pages]]
@Test @MainActor func extensionUpdatesAndPages() async throws {
    guard #available(macOS 15.4, *) else { return }
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseExtensionUpdate-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try extensionFixture(at: root)
    let manager = ExtensionManager(root: root.appendingPathComponent("installed"), persistent: false)
    try await manager.importExtension(from: source)
    let record = try #require(manager.records.first)
    try await manager.enable(true, id: record.id) { _, _ in true }
    let context = try #require(manager.contexts[record.id])
    let configuration = try #require(context.webViewConfiguration)
    let document = ExtensionDocument(manager: manager, context: context, configuration: configuration)
    // Exercise the extension's real document and API namespace without displaying a window.
    let navigation = ExtensionTestNavigation()
    document.web.navigationDelegate = navigation
    try await navigation.load(document.web, url: try #require(context.optionsPageURL))
    #expect(try await document.web.evaluateJavaScript("browser.runtime.id") as? String == record.id.uuidString)
    #expect(try await document.web.evaluateJavaScript("document.body.textContent") as? String == "Options fixture")
    #expect(document.webView(for: context) === document.web)
    // Check runtime primitives separately from a third-party extension's startup.
    let capabilities = try await document.web.callAsyncJavaScript(#"""
        await WebAssembly.instantiate(new Uint8Array([0,97,115,109,1,0,0,0]));
        const database = await new Promise((resolve, reject) => {
            const request = indexedDB.open('BrowseTest');
            request.onupgradeneeded = () => request.result.createObjectStore('values');
            request.onsuccess = () => resolve(request.result);
            request.onerror = () => reject(request.error);
        });
        try {
            await new Promise((resolve, reject) => {
                const transaction = database.transaction('values', 'readwrite');
                transaction.objectStore('values').put('saved', 'key');
                transaction.oncomplete = resolve;
                transaction.onerror = () => reject(transaction.error);
                transaction.onabort = () => reject(transaction.error);
            });
            return await new Promise((resolve, reject) => {
                const request = database.transaction('values').objectStore('values').get('key');
                request.onsuccess = () => resolve(request.result);
                request.onerror = () => reject(request.error);
            });
        } finally { database.close(); }
        """#, arguments: [:], in: nil, contentWorld: .page)
    #expect(capabilities as? String == "saved")

    let manifest = record.source.appendingPathComponent("manifest.json")
    var updated = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
    updated["host_permissions"] = ["http://127.0.0.1/*", "https://new-access.example/*"]
    try JSONSerialization.data(withJSONObject: updated).write(to: manifest)
    let restored = ExtensionManager(root: manager.root, persistent: false)
    restored.start()
    await restored.restorationTask?.value
    #expect(!restored.isEnabled(record.id))
    #expect(restored.failures[record.id] != nil)
    #expect(restored.contexts[record.id]?.hasAccess(to: URL(string: "https://new-access.example/")!) == false)
    try await manager.enable(false, id: record.id) { _, _ in true }
    document.nativeWindow.close()
}

// @lat: [[tests#Owned extension packages and updates]]
@Test @MainActor func extensionOwnedPackages() async throws {
    guard #available(macOS 15.4, *) else { return }
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseOwnedPackages-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try extensionFixture(at: root)
    let archive = root.appendingPathComponent("fixture.xpi")
    let zip = Process()
    zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    zip.arguments = ["-q", "-r", archive.path, "."]
    zip.currentDirectoryURL = source
    try zip.run(); zip.waitUntilExit()
    #expect(zip.terminationStatus == 0)
    // Exercise production persistence in a unique profile, never the user's store.
    let storageIdentifier = UUID()
    let manager = ExtensionManager(root: root.appendingPathComponent("installed"), storageIdentifier: storageIdentifier)
    try await manager.importExtension(from: archive)
    let record = try #require(manager.records.first)
    #expect(manager.ownsPackage(record))
    #expect(record.importedFrom == archive)
    #expect(record.packageIdentifier == "gecko:browse-fixture@example.test")
    try await manager.enable(true, id: record.id) { _, _ in true }
    let origin = manager.contexts[record.id]?.baseURL
    let before = try #require(manager.contexts[record.id])
    var web: WKWebView? = WKWebView(frame: .zero, configuration: try #require(before.webViewConfiguration))
    let navigation = ExtensionTestNavigation()
    web?.navigationDelegate = navigation
    try await navigation.load(try #require(web), url: try #require(before.optionsPageURL))
    _ = try await web?.callAsyncJavaScript("await browser.storage.local.set({updateMarker: 'retained'});", arguments: [:], in: nil, contentWorld: .page)
    web = nil
    try FileManager.default.removeItem(at: archive)
    #expect(FileManager.default.fileExists(atPath: record.source.path))

    let manifest = source.appendingPathComponent("manifest.json")
    var updated = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
    updated["version"] = "2.0"
    try JSONSerialization.data(withJSONObject: updated).write(to: manifest)
    try await manager.replacePackage(record.id, from: source)
    #expect(manager.isEnabled(record.id))
    #expect(manager.contexts[record.id]?.baseURL == origin)
    #expect(manager.contexts[record.id]?.webExtension.version == "2.0")
    let after = try #require(manager.contexts[record.id])
    web = WKWebView(frame: .zero, configuration: try #require(after.webViewConfiguration))
    web?.navigationDelegate = navigation
    try await navigation.load(try #require(web), url: try #require(after.optionsPageURL))
    let marker = try await #require(web).callAsyncJavaScript("return (await browser.storage.local.get('updateMarker')).updateMarker;", arguments: [:], in: nil, contentWorld: .page)
    let storedValue = marker as? String
    #expect(storedValue == "retained")
    web = nil
    #expect(!FileManager.default.fileExists(atPath: record.source.path))
    let current = manager.records[0].source

    updated["browser_specific_settings"] = ["gecko": ["id": "different@example.test"]]
    try JSONSerialization.data(withJSONObject: updated).write(to: manifest)
    do {
        try await manager.replacePackage(record.id, from: source)
        Issue.record("An update with a different extension identity was accepted")
    } catch {}
    #expect(manager.records[0].source == current)
    #expect(manager.isEnabled(record.id))
    let invalid = root.appendingPathComponent("broken.zip")
    try Data("not an archive".utf8).write(to: invalid)
    do {
        try await manager.replacePackage(record.id, from: invalid)
        Issue.record("An invalid update was accepted")
    } catch {}
    #expect(manager.records[0].source == current)
    #expect(manager.isEnabled(record.id))

    updated["browser_specific_settings"] = ["gecko": ["id": "browse-fixture@example.test"]]
    updated["host_permissions"] = ["http://127.0.0.1/*", "https://new-access.example/*"]
    try JSONSerialization.data(withJSONObject: updated).write(to: manifest)
    try await manager.replacePackage(record.id, from: source)
    #expect(!manager.isEnabled(record.id))
    #expect(manager.failures[record.id] != nil)
    #expect(manager.contexts[record.id]?.hasAccess(to: URL(string: "https://new-access.example/")!) == false)
    let restored = ExtensionManager(root: manager.root, storageIdentifier: storageIdentifier)
    restored.start(); await restored.restorationTask?.value
    #expect(restored.contexts[record.id]?.baseURL == origin)
    #expect(!restored.isEnabled(record.id))
    try await manager.uninstall(record.id)
    #expect(manager.records.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: manager.root.appendingPathComponent(record.id.uuidString).path))
    #expect(FileManager.default.fileExists(atPath: manifest.path))
}

// @lat: [[tests#Extension package migration and isolation]]
@Test @MainActor func extensionPackageMigration() async throws {
    guard #available(macOS 15.4, *) else { return }
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowsePackageMigration-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try extensionFixture(at: root)
    try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("internal.js").path, withDestinationPath: "content.js")
    let installed = root.appendingPathComponent("installed")
    try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
    let legacy = ExtensionRecord(id: UUID(), source: source, isBundle: false, name: "Legacy", permissions: ["storage"])
    try JSONEncoder().encode([legacy]).write(to: installed.appendingPathComponent("extensions.json"))
    let manager = ExtensionManager(root: installed, persistent: false)
    manager.start(); await manager.restorationTask?.value
    let record = try #require(manager.records.first)
    #expect(record.id == legacy.id)
    #expect(record.permissions == legacy.permissions)
    #expect(record.source != source)
    #expect(manager.ownsPackage(record))
    try FileManager.default.removeItem(at: source)
    #expect(try String(contentsOf: record.source.appendingPathComponent("internal.js"), encoding: .utf8).contains("browseExtension"))
    let restored = ExtensionManager(root: installed, persistent: false)
    restored.start(); await restored.restorationTask?.value
    #expect(restored.contexts[record.id] != nil)
    #expect(restored.failures.isEmpty)

    let unsafeSource = try extensionFixture(at: root.appendingPathComponent("unsafe"))
    try FileManager.default.createSymbolicLink(at: unsafeSource.appendingPathComponent("outside"), withDestinationURL: installed)
    do {
        try await manager.importExtension(from: unsafeSource)
        Issue.record("A package containing an external symbolic link was accepted")
    } catch {}
    #expect(manager.records.count == 1)
}

@MainActor
private final class ExtensionTestNavigation: NSObject, WKNavigationDelegate {
    var continuation: CheckedContinuation<Void, Error>?
    func load(_ web: WKWebView, url: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            web.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume(); continuation = nil
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error); continuation = nil
    }
}

// @lat: [[tests#Catalog download integrity and identity]]
@Test @MainActor func catalogIntegrityAndIdentity() async throws {
    let data = Data("package fixture".utf8)
    let url = URL(string: "https://example.test/extension.xpi")!
    let download = CatalogDownload(version: "1", url: url,
        sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
    try download.validate(data, response: response)
    #expect(throws: CatalogError.self) { try download.validate(Data("changed".utf8), response: response) }
    #expect(throws: CatalogError.self) { try download.validate(Data(), response: response) }
    #expect(throws: CatalogError.self) {
        try download.validate(data, response: HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
    }
    #expect(throws: CatalogError.self) {
        try download.validate(data, response: HTTPURLResponse(url: URL(string: "http://example.test/package")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    #expect(throws: CatalogError.self) {
        try download.validate(Data(count: CatalogDownload.maximumBytes + 1), response: response)
    }
    guard #available(macOS 15.4, *) else { return }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseCatalogTest-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try extensionFixture(at: root)
    let manager = ExtensionManager(root: root.appendingPathComponent("installed"), persistent: false)
    do {
        try await manager.importExtension(from: source, expectedIdentifier: CatalogExtension.curated[1].packageIdentifier)
        Issue.record("A mismatched catalog identity was accepted")
    } catch { }
    #expect(manager.records.isEmpty)
    let leftovers = FileManager.default.enumerator(at: manager.root, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? []
    #expect(try leftovers.allSatisfy { try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile != true })
    try await manager.importExtension(from: source, expectedIdentifier: "gecko:browse-fixture@example.test")
    let record = try #require(manager.records.first)
    #expect(!manager.isEnabled(record.id))
    #expect(record.permissions.isEmpty)
    #expect(record.websites.isEmpty)
    #expect(manager.catalogRecord(CatalogExtension.curated[1]) == nil)
}

// @lat: [[tests#Catalog package download smoke test]]
@Test(arguments: ["1password", "dark-reader"]) @MainActor func catalogDownloadSmoke(entryID: String) async throws {
    guard #available(macOS 15.4, *), ProcessInfo.processInfo.environment["BROWSE_TEST_CATALOG_DOWNLOAD"] == "1" else { return }
    let entry = try #require(CatalogExtension.curated.first { $0.id == entryID })
    guard case .download(let download) = entry.installation else { Issue.record("Expected downloadable package"); return }
    let data = try await download.fetch()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseCatalogDownload-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("official.xpi")
    try data.write(to: source)
    let manager = ExtensionManager(root: root.appendingPathComponent("installed"), persistent: false)
    try await manager.importExtension(from: source, expectedIdentifier: entry.packageIdentifier)
    let record = try #require(manager.catalogRecord(entry))
    #expect(!manager.isEnabled(record.id))
    #expect(manager.contexts[record.id]?.webExtension.version == download.version)
}

final class ExtensionHTTPFixture: @unchecked Sendable {
    let listener: NWListener
    var port: UInt16 { listener.port!.rawValue }
    init() throws { listener = try NWListener(using: .tcp, on: .any) }
    static func start() async throws -> ExtensionHTTPFixture {
        let server = try ExtensionHTTPFixture()
        server.listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                let request = String(data: data ?? Data(), encoding: .utf8) ?? ""
                let script = request.hasPrefix("GET /blocked.js ")
                let body = script ? "window.blockedScriptRan = true;" : "<html><body>Fixture<script src='/blocked.js'></script></body></html>"
                let type = script ? "text/javascript" : "text/html"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nCache-Control: no-store\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            server.listener.stateUpdateHandler = { state in
                switch state {
                case .ready: server.listener.stateUpdateHandler = nil; continuation.resume()
                case .failed(let error): server.listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            server.listener.start(queue: .global())
        }
        return server
    }
}
