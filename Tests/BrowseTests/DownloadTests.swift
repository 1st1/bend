import AppKit
import Network
import SwiftUI
import Testing
import WebKit
@testable import Browse

@MainActor private func downloadWait(_ predicate: () -> Bool) async throws {
    for _ in 0..<400 {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    try #require(predicate())
}

// @lat: [[tests#Website downloads]]
@Test @MainActor func websiteDownloads() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendDownloads-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let server = try await DownloadHTTPFixture.start()
    defer { server.listener.cancel() }
    let manager = BrowserDownloads(directory: root)
    let page = PageController(address: server.url("/page").absoluteString, downloads: manager,
                              configure: { $0.websiteDataStore = .nonPersistent() })
    let web = page.webView
    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 700, height: 500),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = web; window.orderFront(nil)
    defer { manager.shutdown(); page.media.detach(); web.stopLoading(); window.orderOut(nil); window.contentView = nil }
    try await downloadWait { web.title == "Download fixture" && !web.isLoading }
    try Data("existing".utf8).write(to: root.appendingPathComponent("report.txt"))
    _ = try await web.evaluateJavaScript("document.querySelector('input').value = 'unsaved'; void 0")
    func click(_ id: String, expected: String) async throws -> BrowserDownload {
        let count = manager.items.count
        _ = try await web.evaluateJavaScript("document.getElementById('\(id)').click(); void 0")
        try await downloadWait { manager.items.count == count + 1 }
        let item = try #require(manager.items.first)
        try await downloadWait { item.state == .completed || item.state == .failed }
        try #require(item.state == .completed, "\(item.error ?? "unknown failure")")
        let file = try #require(item.fileURL)
        #expect(try String(contentsOf: file, encoding: .utf8) == expected)
        #expect(web.url == server.url("/page"))
        #expect(page.error == nil)
        #expect(try await web.evaluateJavaScript("document.querySelector('input').value") as? String == "unsaved")
        return item
    }
    let first = try await click("attachment", expected: "attachment payload")
    #expect(first.name == "report (1).txt")
    #expect(try String(contentsOf: root.appendingPathComponent("report.txt"), encoding: .utf8) == "existing")
    let second = try await click("attachment", expected: "attachment payload")
    #expect(second.name == "report (2).txt")
    _ = try await click("explicit", expected: "plain payload")
    _ = try await click("unsupported", expected: "binary payload")
    _ = try await click("redirect", expected: "authenticated payload")
    _ = try await click("post", expected: "posted payload")
    _ = try await click("blob", expected: "generated payload")
    _ = try await click("data", expected: "data payload")
    #expect(manager.activeCount == 0)
    #expect(page.error == nil)
    #expect(try !FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".bend-download-") })
    if let path = ProcessInfo.processInfo.environment["BEND_DOWNLOADS_SNAPSHOT"] {
        let preview = NSHostingView(rootView: DownloadsList(downloads: manager))
        let previewWindow = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 360, height: 430),
                                     styleMask: [.borderless], backing: .buffered, defer: false)
        previewWindow.isReleasedWhenClosed = false
        previewWindow.contentView = preview; previewWindow.orderFront(nil)
        defer { previewWindow.close() }
        for _ in 0..<5 { preview.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(40)) }
        let bitmap = try #require(preview.bitmapImageRepForCachingDisplay(in: preview.bounds))
        preview.cacheDisplay(in: preview.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
    manager.clearFinished()
    #expect(manager.items.isEmpty)
    #expect(FileManager.default.fileExists(atPath: first.fileURL!.path))
    page.show(NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost))
    #expect(page.error != nil)
}

// @lat: [[tests#Download cancellation and retry]]
@Test @MainActor func downloadCancellationAndRetry() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendDownloadRetry-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let server = try await DownloadHTTPFixture.start()
    defer { server.listener.cancel() }
    let manager = BrowserDownloads(directory: root)
    var page: PageController? = PageController(address: server.url("/page").absoluteString, downloads: manager,
                                               configure: { $0.websiteDataStore = .nonPersistent() })
    defer { manager.shutdown(); page?.media.detach(); page?.webView.stopLoading() }
    try await downloadWait { page?.webView.title == "Download fixture" }
    manager.start(URLRequest(url: server.url("/slow")), in: page!.webView)
    try await downloadWait { manager.items.first?.received ?? 0 > 0 }
    let item = try #require(manager.items.first)
    #expect(manager.activeCount == 1)
    #expect(manager.progressFraction.map { $0 > 0 && $0 < 1 } == true)
    manager.cancel(item)
    try await downloadWait { item.state == .cancelled }
    #expect(item.fileURL == nil)
    #expect(item.canRetry)
    #expect(manager.activeCount == 0)
    #expect(manager.progressFraction == nil)
    page?.media.detach(); page?.webView.stopLoading(); page = nil
    manager.retry(item)
    try await downloadWait { item.state == .completed || item.state == .failed }
    try #require(item.state == .completed, "\(item.error ?? "unknown retry failure")")
    #expect(try Data(contentsOf: #require(item.fileURL)).count == DownloadHTTPFixture.slowSize)

    let context = WKWebView()
    manager.start(URLRequest(url: server.url("/failure")), in: context)
    try await downloadWait { manager.items.first?.state == .failed }
    let failed = try #require(manager.items.first)
    #expect(failed.error?.contains("503") == true)
    #expect(failed.fileURL == nil && failed.canRetry)
    server.allowRetry()
    manager.retry(failed)
    try await downloadWait { failed.state == .completed || failed.state == .failed }
    #expect(failed.state == .completed)
    #expect(manager.activeCount == 0)
    var closingContext: WKWebView? = WKWebView()
    let countBeforeClosing = manager.items.count
    manager.start(URLRequest(url: server.url("/slow")), in: closingContext!)
    try await downloadWait { manager.items.count == countBeforeClosing + 1 }
    try await downloadWait { manager.items.first?.received ?? 0 > 0 }
    let independent = try #require(manager.items.first)
    closingContext = nil
    try await downloadWait { independent.state == .completed || independent.state == .failed }
    #expect(independent.state == .completed)
    #expect(try Data(contentsOf: #require(independent.fileURL)).count == DownloadHTTPFixture.slowSize)
}

// @lat: [[tests#Download filenames]]
@Test @MainActor func downloadFilenames() {
    for input in ["../../escape.txt", "C:\\folder\\escape.txt", ".hidden", "..", "", "a\u{202E}txt.exe", "a\nfile.txt", String(repeating: "🦊", count: 300)] {
        let name = BrowserDownloads.safeFilename(input)
        #expect(!name.isEmpty && !name.hasPrefix("."))
        #expect(!name.contains("/") && !name.contains("\\") && !name.contains(":"))
        #expect(name.utf8.count <= 200)
        #expect(!name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .format })
    }
    #expect(BrowserDownloads.safeFilename("../../escape.txt") == "escape.txt")
    #expect(!BrowserDownloads.supports(URL(string: "file:///etc/passwd")))
    #expect(!BrowserDownloads.supports(URL(string: "someapp://open")))
}

// @lat: [[tests#Persistent download history]]
@Test @MainActor func persistentDownloadHistory() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendPersistentDownloads-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("Downloads.db")
    let directory = root.appendingPathComponent("files")
    let server = try await DownloadHTTPFixture.start()
    defer { server.listener.cancel() }
    let manager = BrowserDownloads(directory: directory, databaseFile: file)
    defer { manager.shutdown() }
    let web = WKWebView()
    manager.start(URLRequest(url: server.url("/attachment")), in: web)
    try await downloadWait { manager.items.first?.state == .completed }
    let completed = try #require(manager.items.first).record
    manager.start(URLRequest(url: server.url("/slow")), in: web)
    try await downloadWait { manager.items.count == 2 && (manager.items.first?.received ?? 0) > 0 }
    manager.shutdown()
    let restored = BrowserDownloads(directory: directory, databaseFile: file)
    defer { restored.shutdown() }
    #expect(restored.items.count == 2)
    #expect(restored.items[1].record == completed)
    let interrupted = restored.items[0]
    #expect(interrupted.state == .failed && interrupted.canRetry)
    #expect(restored.activeCount == 0)
    restored.retry(interrupted)
    try await downloadWait { interrupted.state == .completed || interrupted.state == .failed }
    #expect(interrupted.state == .completed)
    #expect(try Data(contentsOf: #require(interrupted.fileURL)).count == DownloadHTTPFixture.slowSize)
    restored.clearFinished()
    #expect(try DownloadDatabase(file: file).load().isEmpty)
    #expect(FileManager.default.fileExists(atPath: try #require(completed.fileURL).path))

    // Loading a full history and adding a real transfer prunes metadata only.
    let records = (0..<256).map { DownloadRecord(name: "old \($0)", state: .completed, fileURL: completed.fileURL, directory: directory) }
    try DownloadDatabase(file: file).save(records)
    let capped = BrowserDownloads(directory: directory, databaseFile: file)
    defer { capped.shutdown() }
    capped.start(URLRequest(url: server.url("/attachment")), in: web)
    try await downloadWait { capped.items.first?.id != records.first!.id && capped.items.first?.state == .completed }
    #expect(capped.items.count == 256)
    #expect(!capped.items.contains { $0.id == records.last!.id })
    #expect(try DownloadDatabase(file: file).load().count == 256)
    #expect(FileManager.default.fileExists(atPath: try #require(completed.fileURL).path))
}

// @lat: [[tests#Downloads with collapsed sidebar]]
@Test @MainActor func downloadsWithCollapsedSidebar() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendDownloadChrome-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let owner = BrowserWindows(root: root, persistentExtensions: false)
    owner.restore(show: false)
    let context = try #require(owner.active)
    let store = context.store
    store.downloadDirectory = root.appendingPathComponent("files")
    context.window.setFrame(NSRect(x: -10000, y: -10000, width: 1100, height: 700), display: true)
    context.window.orderFront(nil)
    defer { owner.prepareToQuit(); context.window.close() }
    let server = try await DownloadHTTPFixture.start()
    defer { server.listener.cancel() }
    let web = WKWebView()
    store.downloads.start(URLRequest(url: server.url("/attachment")), in: web)
    try await downloadWait { store.downloads.items.first?.state == .completed }
    func controls(_ view: NSView) -> [NSRect] {
        var result = view.subviews.flatMap { controls($0) }
        if let area = view as? WindowDragAreaView, area.excluded, !area.isHiddenOrHasHiddenAncestor,
           abs(area.bounds.width - 28) < 0.5, abs(area.bounds.height - 28) < 0.5 {
            let frame = area.convert(area.bounds, to: nil)
            if abs(context.window.frame.height - frame.midY - Chrome.headerCenterY) < 0.5 {
                result.append(frame)
            }
        }
        return result.sorted { $0.minX < $1.minX }
    }
    for (index, visible) in [true, false, false, false, true].enumerated() {
        store.sidebarVisible = visible
        if index == 2 { store.toggleZoom(store.selectedTab.pages.last!.id) }
        if index == 3 { store.newTab(address: "browse://guide") }
        for _ in 0..<6 {
            context.window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
        }
        let frames = controls(try #require(context.window.contentView))
        // The pair keeps its sidebar sizing and spacing in both layouts.
        try #require(frames.count == 2)
        #expect(abs(frames[1].minX - frames[0].maxX - 2) < 0.5)
        let frame = try #require(frames.first)
        #expect(frame.minX >= 0 && frame.maxX <= context.window.frame.width)
        if !visible { #expect(frame.midX < 180) }
        if let path = ProcessInfo.processInfo.environment["BEND_DOWNLOAD_CHROME_SNAPSHOT"], index == 1,
           let content = context.window.contentView,
           let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }
    store.downloads.clearFinished()
    for _ in 0..<5 { try await Task.sleep(for: .milliseconds(40)) }
    #expect(controls(try #require(context.window.contentView)).count == 1)
}

// @lat: [[tests#Download-only tabs]]
@Test @MainActor func downloadOnlyTabs() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendDownloadTabs-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let server = try await DownloadHTTPFixture.start()
    defer { server.listener.cancel() }
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    store.downloadDirectory = root.appendingPathComponent("files")
    let original = store.selectedTab
    let source = store.controller(for: original.pages[0])
    source.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
    source.navigate(server.url("/page").absoluteString)
    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 700, height: 500),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = source.webView; window.orderFront(nil)
    defer {
        store.downloads.shutdown()
        for page in store.session.workspaces.flatMap(\.tabs).flatMap(\.pages) {
            store.existingController(for: page.id)?.media.detach()
            store.existingController(for: page.id)?.webView.stopLoading()
        }
        window.orderOut(nil); window.contentView = nil
    }
    try await downloadWait { source.webView.title == "Download fixture" && !source.webView.isLoading }
    _ = try await source.webView.evaluateJavaScript("document.querySelector('input').value = 'unsaved'; void 0")
    for id in ["new-download", "new-redirect"] {
        let count = store.downloads.items.count
        _ = try await source.webView.evaluateJavaScript("document.getElementById('\(id)').click(); void 0")
        try await downloadWait { store.downloads.items.count == count + 1 }
        #expect(store.session.workspaces.flatMap(\.tabs).count == 1)
        #expect(store.selectedTab.id == original.id)
        #expect(!store.canReopenClosed)
        #expect(source.error == nil)
        let item = try #require(store.downloads.items.first)
        try await downloadWait { item.state == .completed || item.state == .failed }
        #expect(item.state == .completed)
        #expect(try Data(contentsOf: #require(item.fileURL)).count == DownloadHTTPFixture.slowSize)
        #expect(try await source.webView.evaluateJavaScript("document.querySelector('input').value") as? String == "unsaved")
    }
    // A later selection must not be stolen when the download tab disappears.
    source.onNewLink?(server.url("/slow").absoluteString, false, true)
    store.newTab(address: "browse://guide")
    let selectedElsewhere = store.selectedTab.id
    try await downloadWait { store.downloads.items.count == 3 }
    #expect(store.selectedTab.id == selectedElsewhere)
    #expect(store.session.workspaces.flatMap(\.tabs).count == 2)

    // A new-window page that committed a document is a normal tab thereafter.
    source.onNewLink?(server.url("/page").absoluteString, false, true)
    let regularTab = store.selectedTab
    let regular = store.controller(for: regularTab.pages[0])
    try await downloadWait { regular.webView.title == "Download fixture" && !regular.webView.isLoading }
    _ = try await regular.webView.evaluateJavaScript("document.getElementById('attachment').click(); void 0")
    try await downloadWait { store.downloads.items.count == 4 }
    #expect(store.selectedTab.id == regularTab.id)
    #expect(store.session.workspaces.flatMap(\.tabs).count == 3)
    #expect(regular.error == nil)

    // Context-menu tabs load without being selected, including download handoff.
    store.select(original.id)
    store.zoomedPane = original.focusedPane
    source.onOpenLink?(server.url("/slow").absoluteString, true, .newTab)
    #expect(store.selectedTab.id == original.id)
    #expect(store.zoomedPane == original.focusedPane)
    try await downloadWait { store.downloads.items.count == 5 }
    #expect(store.session.workspaces.flatMap(\.tabs).count == 3)
    #expect(store.selectedTab.id == original.id)
    #expect(store.zoomedPane == original.focusedPane)
    #expect(!store.canReopenClosed)
    let existingIDs = Set(store.session.workspaces.flatMap(\.tabs).map(\.id))
    source.onOpenLink?(server.url("/page").absoluteString, true, .newTab)
    let backgroundTab = try #require(store.session.workspaces.flatMap(\.tabs).first { !existingIDs.contains($0.id) })
    let background = try #require(store.existingController(for: backgroundTab.pages[0].id))
    try await downloadWait { background.webView.title == "Download fixture" && !background.webView.isLoading }
    #expect(store.selectedTab.id == original.id)
    #expect(store.selectedTab.focusedPane == original.focusedPane)
    #expect(store.zoomedPane == original.focusedPane)
    #expect(try await source.webView.evaluateJavaScript("document.querySelector('input').value") as? String == "unsaved")
}

// @lat: [[tests#Download destination preferences]]
@Test @MainActor func downloadDestinationPreferences() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendDownloadPreferences-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("session.json")
    let store = BrowserStore(sessionFile: file, persistentExtensions: false)
    let other = BrowserStore(sessionFile: root.appendingPathComponent("other.json"), persistentExtensions: false, sharedStore: store)
    defer { store.downloads.shutdown() }
    #expect(store.downloadDirectory == BrowserDownloads.defaultDirectory)
    let original = root.appendingPathComponent("first", isDirectory: true)
    let changed = root.appendingPathComponent("second", isDirectory: true)
    store.downloadDirectory = original
    #expect(other.downloadDirectory == original)
    let server = try await DownloadHTTPFixture.start()
    defer { server.listener.cancel() }
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let web = WKWebView(frame: .zero, configuration: configuration)
    store.downloads.start(URLRequest(url: server.url("/slow")), in: web)
    try await downloadWait { store.downloads.items.first?.received ?? 0 > 0 }
    let active = try #require(store.downloads.items.first)
    other.downloadDirectory = changed
    store.save()
    let restored = BrowserStore(sessionFile: file, persistentExtensions: false)
    defer { restored.downloads.shutdown() }
    #expect(restored.downloadDirectory == changed)
    #expect(restored.downloads.directory == changed)
    try await downloadWait { active.state == .completed || active.state == .failed }
    #expect(active.fileURL?.deletingLastPathComponent() == original)
    store.downloads.start(URLRequest(url: server.url("/attachment")), in: web)
    try await downloadWait { store.downloads.items.count == 2 && store.downloads.items.first?.state == .completed }
    #expect(store.downloads.items.first?.fileURL?.deletingLastPathComponent() == changed)
    store.downloadDirectory = BrowserDownloads.defaultDirectory
    store.save()
    #expect(store.session.downloadDirectory == nil)
    #expect(other.downloadDirectory == BrowserDownloads.defaultDirectory)
}

private final class DownloadHTTPFixture: @unchecked Sendable {
    static let slowSize = 512 * 1024
    let listener: NWListener
    private let queue = DispatchQueue(label: "Bend.download-fixture")
    private let lock = NSLock()
    private var retryAllowed = false
    func allowRetry() { lock.withLock { retryAllowed = true } }
    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)\(path)")! }
    private init() throws { listener = try NWListener(using: .tcp, on: .any) }

    static func start() async throws -> DownloadHTTPFixture {
        let server = try DownloadHTTPFixture()
        server.listener.newConnectionHandler = { [weak server] connection in
            guard let server else { connection.cancel(); return }
            connection.start(queue: server.queue)
            server.read(connection, accumulated: Data())
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            server.listener.stateUpdateHandler = { state in
                switch state {
                case .ready: server.listener.stateUpdateHandler = nil; continuation.resume()
                case .failed(let error): server.listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            server.listener.start(queue: server.queue)
        }
        return server
    }

    private func read(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, complete, error in
            let bytes = accumulated + (data ?? Data())
            guard error == nil, bytes.count < 128 * 1024 else { connection.cancel(); return }
            if let separator = bytes.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: bytes[..<separator.lowerBound], as: UTF8.self)
                let length = head.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                if bytes.count - separator.upperBound >= length {
                    respond(connection, request: String(decoding: bytes, as: UTF8.self)); return
                }
            }
            if complete { connection.cancel() } else { read(connection, accumulated: bytes) }
        }
    }

    private func respond(_ connection: NWConnection, request: String) {
        let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        var status = "200 OK"
        var headers = "Content-Type: text/plain\r\nContent-Disposition: attachment; filename=report.txt\r\n"
        var text = "attachment payload"
        if path == "/page" {
            headers = "Content-Type: text/html\r\nSet-Cookie: download-token=ok; Path=/\r\n"
            text = """
            <title>Download fixture</title><input value='draft'>
            <a id='attachment' href='/attachment'>Attachment</a>
            <a id='new-download' href='/slow' target='_blank'>Download in new tab</a>
            <a id='new-redirect' href='/download-redirect' target='_blank'>Redirect in new tab</a>
            <a id='explicit' href='/plain' download='plain.txt'>Download</a>
            <a id='unsupported' href='/binary'>Binary</a>
            <a id='redirect' href='/redirect'>Redirect</a>
            <form method='POST' action='/post'><input name='token' value='hello'><button id='post'>Submit</button></form>
            <a id='blob' download='generated.txt'>Blob</a>
            <a id='data' download='data.txt' href='data:text/plain,data%20payload'>Data</a>
            <script>document.getElementById('blob').href = URL.createObjectURL(new Blob(['generated payload'], {type:'text/plain'}));</script>
            """
        } else if path == "/plain" {
            headers = "Content-Type: text/plain\r\n"; text = "plain payload"
        } else if path == "/binary" {
            headers = "Content-Type: application/octet-stream\r\n"; text = "binary payload"
        } else if path == "/download-redirect" {
            status = "302 Found"; headers = "Location: /slow\r\n"; text = ""
        } else if path == "/redirect" {
            status = "302 Found"; headers = "Location: /protected\r\n"; text = ""
        } else if path == "/protected" {
            if request.contains("download-token=ok") { text = "authenticated payload" }
            else { status = "401 Unauthorized"; text = "missing cookie" }
        } else if path == "/post" {
            if request.hasPrefix("POST ") && request.contains("token=hello") { text = "posted payload" }
            else { status = "400 Bad Request"; text = "missing post body" }
        } else if path == "/failure", !lock.withLock({ retryAllowed }) {
            status = "503 Service Unavailable"; text = "try again"
        } else if path == "/slow" {
            let range = request.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("range: bytes=") }
            let offset = range.flatMap { Int($0.components(separatedBy: "=").last!.split(separator: "-")[0]) } ?? 0
            if offset > 0 { status = "206 Partial Content"; headers += "Content-Range: bytes \(offset)-\(Self.slowSize - 1)/\(Self.slowSize)\r\n" }
            headers += "Accept-Ranges: bytes\r\nETag: \"slow-file\"\r\n"
            let head = "HTTP/1.1 \(status)\r\n\(headers)Content-Length: \(Self.slowSize - offset)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8), completion: .contentProcessed { [self] _ in sendChunk(connection, remaining: Self.slowSize - offset) })
            return
        }
        let body = Data(text.utf8)
        let head = "HTTP/1.1 \(status)\r\n\(headers)Cache-Control: no-store\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func sendChunk(_ connection: NWConnection, remaining: Int) {
        guard remaining > 0 else { connection.cancel(); return }
        let size = min(32768, remaining)
        connection.send(content: Data(repeating: 90, count: size), completion: .contentProcessed { [self] error in
            guard error == nil else { connection.cancel(); return }
            queue.asyncAfter(deadline: .now() + 0.08) { [self] in sendChunk(connection, remaining: remaining - size) }
        })
    }
}
