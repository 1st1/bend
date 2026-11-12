import AppKit
import Combine
import WebKit
import Darwin

@MainActor
final class BrowserDownload: ObservableObject, Identifiable {
    typealias State = DownloadRecord.State
    let id: UUID
    @Published var name = "Download"
    @Published var state = State.downloading
    @Published var received: Int64 = 0
    @Published var total: Int64 = 0
    @Published var error: String?
    @Published var fileURL: URL?
    var sourceURL: URL? { request?.url }
    var canRetry: Bool {
        guard state == .failed || state == .cancelled else { return false }
        return readyToPublish || resumeData != nil ||
            (["http", "https"].contains(request?.url?.scheme?.lowercased() ?? "") &&
             (request?.httpMethod ?? "GET") == "GET")
    }
    fileprivate var request: URLRequest?
    fileprivate var download: WKDownload?
    fileprivate var resumeData: Data?
    fileprivate var stagingDirectory: URL?
    fileprivate var stagingFile: URL?
    fileprivate var readyToPublish = false
    fileprivate var dockProgress: DownloadDockProgress?
    fileprivate var animationRect: NSRect?
    fileprivate weak var webView: WKWebView?
    fileprivate var retryWebView: WKWebView?
    fileprivate let dataStore: WKWebsiteDataStore
    fileprivate let directory: URL

    init(request: URLRequest?, webView: WKWebView, directory: URL) {
        id = UUID()
        self.request = request
        self.directory = directory
        self.webView = webView
        if let window = webView.window, window.isVisible {
            let bounds = webView.bounds
            let rect = NSRect(x: bounds.midX - 16, y: bounds.midY - 16, width: 32, height: 32)
            animationRect = window.convertToScreen(webView.convert(rect, to: nil))
        }
        dataStore = webView.configuration.websiteDataStore
    }

    init(record: DownloadRecord) {
        id = record.id; directory = record.directory
        dataStore = AppProfile.current.websiteDataStore
        name = record.name; state = record.state
        received = max(0, record.received); total = max(0, record.total)
        error = record.error; fileURL = record.fileURL
        if let url = record.sourceURL, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            request = URLRequest(url: url)
            request?.httpMethod = record.method
        }
        if state == .downloading || state == .cancelling {
            state = .failed
            error = "Interrupted when Bend closed."
        }
    }

    var record: DownloadRecord {
        // Keep request headers, cookies, POST bodies and WebKit resume data in
        // memory only. Generated data URLs can contain entire files.
        var source: URL?
        if let url = sourceURL, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.user = nil; components.password = nil
            source = components.url
        }
        return DownloadRecord(id: id, name: name, state: state, received: received, total: total,
                              error: error, fileURL: fileURL, sourceURL: source,
                              method: request?.httpMethod ?? "GET", directory: directory)
    }
}

// @lat: [[lat.md/architecture/downloads#Dock download progress]]
@MainActor
final class DownloadDockProgress {
    let progress = Progress(totalUnitCount: -1)
    private(set) var isPublished = true

    init(url: URL, animationRect: NSRect?) {
        progress.kind = .file
        progress.fileOperationKind = .downloading
        progress.fileURL = url
        progress.isCancellable = false
        progress.isPausable = false
        if let animationRect, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            progress.setUserInfoObject(NSWorkspace.shared.icon(forFile: url.path), forKey: .fileAnimationImageKey)
            progress.setUserInfoObject(NSValue(rect: animationRect), forKey: .fileAnimationImageOriginalRectKey)
        }
        progress.publish()
    }

    func update(received: Int64, total: Int64) {
        guard isPublished else { return }
        progress.totalUnitCount = total > 0 ? total : -1
        // Completion means the file has been atomically moved out of staging.
        progress.completedUnitCount = total > 0 ? min(max(0, received), total - 1) : max(0, received)
    }

    func finish(url: URL?) {
        guard isPublished else { return }
        if let url {
            progress.fileURL = url
            progress.totalUnitCount = max(1, progress.totalUnitCount)
            progress.completedUnitCount = progress.totalUnitCount
        } else {
            progress.cancel()
        }
        progress.unpublish()
        isPublished = false
    }

    deinit {
        if isPublished { progress.unpublish() }
    }
}

// @lat: [[lat.md/architecture/downloads#Browser downloads]]
@MainActor
final class BrowserDownloads: NSObject, ObservableObject, WKDownloadDelegate {
    @Published private(set) var items: [BrowserDownload] = []
    @Published private(set) var activeCount = 0
    @Published private(set) var progressFraction: Double?
    @Published private(set) var persistenceError: String?
    static var defaultDirectory: URL { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0] }
    var directory: URL
    private var running: [ObjectIdentifier: BrowserDownload] = [:]
    private var pendingRetries: [UUID: BrowserDownload] = [:]
    private var polling: Task<Void, Never>?
    private var stopped = false
    private let databaseFile: URL?
    private var database: DownloadDatabase?

    init(directory: URL = BrowserDownloads.defaultDirectory, databaseFile: URL? = nil) {
        self.directory = directory
        self.databaseFile = databaseFile
        super.init()
        retryPersistence()
    }

    func receive(_ download: WKDownload, from webView: WKWebView) {
        guard !stopped else { download.cancel(nil); return }
        let item = BrowserDownload(request: download.originalRequest, webView: webView, directory: directory)
        if let name = download.originalRequest?.url?.lastPathComponent, !name.isEmpty {
            item.name = Self.safeFilename(name)
        }
        items.insert(item, at: 0)
        trimHistory()
        attach(download, to: item)
    }

    func start(_ request: URLRequest, in webView: WKWebView) {
        guard Self.supports(request.url), !stopped else { return }
        webView.startDownload(using: request) { [weak self, weak webView] download in
            guard let self, let webView else { download.cancel(nil); return }
            self.receive(download, from: webView)
        }
    }

    static func supports(_ url: URL?) -> Bool {
        ["http", "https", "blob", "data"].contains(url?.scheme?.lowercased() ?? "")
    }

    private func attach(_ download: WKDownload, to item: BrowserDownload) {
        guard !stopped, item.state == .downloading else { download.cancel(nil); return }
        item.download = download
        pendingRetries[item.id] = nil
        item.request = download.originalRequest ?? item.request
        running[ObjectIdentifier(download)] = item
        download.delegate = self
        if item.stagingFile != nil { startDockProgress(item) }
        updateActivity()
        persist()
    }

    func cancel(_ item: BrowserDownload) {
        guard item.state == .downloading else { return }
        guard let download = item.download else {
            finish(item, state: .cancelled)
            return
        }
        item.state = .cancelling
        download.cancel { [weak self, weak item] data in
            guard let self, let item, item.download === download else { return }
            item.resumeData = data
            if data == nil { self.removeStaging(item) }
            self.finish(item, state: .cancelled)
        }
    }

    func retry(_ item: BrowserDownload) {
        guard item.canRetry, !stopped else { return }
        item.error = nil
        if item.readyToPublish { startDockProgress(item); publish(item); return }
        item.state = .downloading
        let web: WKWebView
        if let original = item.webView { web = original }
        else {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = item.dataStore
            web = WKWebView(frame: .zero, configuration: config)
        }
        // Retain the retry context until WebKit has finished the transfer.
        item.retryWebView = web
        pendingRetries[item.id] = item
        updateActivity()
        persist()
        let started: @MainActor @Sendable (WKDownload) -> Void = { [weak self, weak item] download in
            guard let self, let item else { download.cancel(nil); return }
            self.attach(download, to: item)
        }
        if let data = item.resumeData {
            item.resumeData = nil
            web.resumeDownload(fromResumeData: data, completionHandler: started)
        } else if let request = item.request {
            removeStaging(item)
            item.received = 0; item.total = 0
            web.startDownload(using: request, completionHandler: started)
        }
    }

    func reveal(_ item: BrowserDownload) {
        guard item.state == .completed, let url = item.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func clearFinished() {
        for item in items where item.state != .downloading && item.state != .cancelling { removeStaging(item) }
        items.removeAll { $0.state != .downloading && $0.state != .cancelling }
        persist()
    }

    func shutdown() {
        guard !stopped else { return }
        stopped = true
        polling?.cancel(); polling = nil
        for item in retainedItems {
            item.dockProgress?.finish(url: nil)
            item.dockProgress = nil
            item.download?.delegate = nil
            item.download?.cancel(nil)
            item.download = nil
            item.retryWebView = nil
            if item.state == .downloading || item.state == .cancelling {
                item.state = .failed
                item.error = "Interrupted when Bend closed."
            }
            item.resumeData = nil
            item.readyToPublish = false
            removeStaging(item)
        }
        running.removeAll()
        pendingRetries.removeAll()
        refreshProgress()
        persist()
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
        guard let item = running[ObjectIdentifier(download)], item.state == .downloading else {
            completionHandler(nil); return
        }
        item.name = Self.safeFilename(suggestedFilename)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            item.error = "The server returned HTTP \(http.statusCode)."
            finish(item, state: .failed)
            completionHandler(nil)
            return
        }
        do {
            let directory = item.directory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            removeStaging(item)
            let staging = directory.appendingPathComponent(".bend-download-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            item.stagingDirectory = staging
            item.stagingFile = staging.appendingPathComponent(item.name)
            startDockProgress(item)
            persist()
            completionHandler(item.stagingFile)
        } catch {
            item.error = error.localizedDescription
            finish(item, state: .failed)
            completionHandler(nil)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = running[ObjectIdentifier(download)], item.state == .downloading else { return }
        item.received = download.progress.completedUnitCount
        item.total = download.progress.totalUnitCount
        item.readyToPublish = true
        publish(item)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = running[ObjectIdentifier(download)], item.state == .downloading else { return }
        item.resumeData = resumeData
        item.error = error.localizedDescription
        if resumeData == nil { removeStaging(item) }
        finish(item, state: .failed)
    }

    func download(_ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, decisionHandler: @escaping @MainActor @Sendable (WKDownload.RedirectPolicy) -> Void) {
        decisionHandler(["http", "https"].contains(request.url?.scheme?.lowercased() ?? "") ? .allow : .cancel)
    }

    func download(_ download: WKDownload, didReceive challenge: URLAuthenticationChallenge,
                  completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.performDefaultHandling, nil)
    }

    static func safeFilename(_ suggested: String) -> String {
        let leaf = suggested.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? "Download"
        var name = String(leaf.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .format && $0 != ":"
        }).trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        while name.utf8.count > 200 { name.removeLast() }
        return name.isEmpty ? "Download" : name
    }

    private func publish(_ item: BrowserDownload) {
        guard let source = item.stagingFile else {
            item.error = "The downloaded file is unavailable."
            item.readyToPublish = false
            finish(item, state: .failed)
            return
        }
        let filename = item.name as NSString
        let ext = filename.pathExtension
        let stem = ext.isEmpty ? item.name : filename.deletingPathExtension
        for suffix in 0..<10_000 {
            let name = suffix == 0 ? item.name : "\(stem) (\(suffix))" + (ext.isEmpty ? "" : ".\(ext)")
            let target = item.directory.appendingPathComponent(name)
            // Atomic no-replace rename: even another process racing us cannot
            // have an existing file overwritten. Native quarantine follows it.
            if renamex_np(source.path, target.path, UInt32(RENAME_EXCL)) == 0 {
                item.name = name
                item.fileURL = target
                item.readyToPublish = false
                item.resumeData = nil
                removeStaging(item)
                finish(item, state: .completed)
                return
            }
            let code = errno
            if code == EEXIST { continue }
            item.error = NSError(domain: NSPOSIXErrorDomain, code: Int(code)).localizedDescription
            finish(item, state: .failed)
            return
        }
        item.error = "Too many files already use this name."
        finish(item, state: .failed)
    }

    private func removeStaging(_ item: BrowserDownload) {
        if let folder = item.stagingDirectory { try? FileManager.default.removeItem(at: folder) }
        item.stagingDirectory = nil; item.stagingFile = nil
    }

    private func startDockProgress(_ item: BrowserDownload) {
        guard item.dockProgress == nil else { return }
        item.dockProgress = DownloadDockProgress(url: item.directory.appendingPathComponent(item.name),
                                                 animationRect: item.animationRect)
    }

    private func finish(_ item: BrowserDownload, state: BrowserDownload.State) {
        item.dockProgress?.finish(url: state == .completed ? item.fileURL : nil)
        item.dockProgress = nil
        pendingRetries[item.id] = nil
        if let download = item.download {
            running.removeValue(forKey: ObjectIdentifier(download))
            download.delegate = nil
        }
        item.download = nil
        item.retryWebView = nil
        item.state = state
        if !items.contains(where: { $0.id == item.id }) { removeStaging(item) }
        updateActivity()
        persist()
    }

    private var retainedItems: [BrowserDownload] {
        var retained = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        for item in running.values { retained[item.id] = item }
        for item in pendingRetries.values { retained[item.id] = item }
        return Array(retained.values)
    }

    private func trimHistory() {
        for item in items.dropFirst(DownloadDatabase.limit) where item.state != .downloading && item.state != .cancelling {
            removeStaging(item)
        }
        items = Array(items.prefix(DownloadDatabase.limit))
    }

    func retryPersistence() {
        guard let databaseFile else { return }
        do {
            if database == nil {
                let opened = try DownloadDatabase(file: databaseFile)
                let existing = Set(items.map(\.id))
                items += opened.load().filter { !existing.contains($0.id) }.map(BrowserDownload.init(record:))
                trimHistory()
                database = opened
            }
            persist()
        } catch { persistenceError = "Download history could not be read: \(error.localizedDescription)" }
    }

    private func persist() {
        guard let database else { return }
        do {
            try database.save(items.map(\.record))
            persistenceError = nil
        } catch { persistenceError = "Download history could not be saved: \(error.localizedDescription)" }
    }

    static func combinedProgress(_ amounts: [(received: Int64, total: Int64)]) -> Double? {
        guard !amounts.isEmpty, amounts.allSatisfy({ $0.total > 0 }) else { return nil }
        let total = amounts.reduce(0.0) { $0 + Double($1.total) }
        let received = amounts.reduce(0.0) { $0 + Double(min(max(0, $1.received), $1.total)) }
        return received / total
    }

    private func refreshProgress() {
        let active = retainedItems.filter { $0.state == .downloading || $0.state == .cancelling }
        if activeCount != active.count { activeCount = active.count }
        let fraction = Self.combinedProgress(active.map { ($0.received, $0.total) })
        if progressFraction != fraction { progressFraction = fraction }
    }

    private func updateActivity() {
        refreshProgress()
        guard activeCount > 0, polling == nil else { return }
        polling = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.activeCount > 0 else { break }
                for item in self.running.values {
                    guard let progress = item.download?.progress else { continue }
                    if item.received != progress.completedUnitCount { item.received = progress.completedUnitCount }
                    if item.total != progress.totalUnitCount { item.total = progress.totalUnitCount }
                    item.dockProgress?.update(received: item.received, total: item.total)
                }
                self.refreshProgress()
                do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
            }
            self?.polling = nil
        }
    }
}
