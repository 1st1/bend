import Combine
import Foundation

// @lat: [[architecture#Extension updates]]
enum ExtensionUpdateSource: Sendable {
    case mozilla(slug: String)
    case uBlockSafari

    var metadataURL: URL {
        switch self {
        case .mozilla(let slug): URL(string: "https://addons.mozilla.org/api/v5/addons/addon/\(slug)/")!
        case .uBlockSafari: URL(string: "https://github.com/uBlockOrigin/uBOL-home/releases/latest")!
        }
    }

    func latest(packageIdentifier: String) async throws -> CatalogDownload {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, url) = try await fetchMetadata(metadataURL, session: session)
        switch self {
        case .mozilla:
            return try parse(data, packageIdentifier: packageIdentifier)
        case .uBlockSafari:
            let version = try GitHubReleasePage.version(from: url)
            let assetsURL = URL(string: "https://github.com/uBlockOrigin/uBOL-home/releases/expanded_assets/\(version)")!
            let (assets, finalURL) = try await fetchMetadata(assetsURL, session: session)
            guard finalURL == assetsURL else { throw CatalogError.invalidResponse }
            return try GitHubReleasePage.download(from: assets, version: version, packageIdentifier: packageIdentifier)
        }
    }

    private func fetchMetadata(_ url: URL, session: URLSession) async throws -> (Data, URL) {
        var request = URLRequest(url: url)
        request.setValue(url.host == "github.com" ? "text/html" : "application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bend-Extension-Updater", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 429 ||
            (http.statusCode == 403 && http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0") {
            throw UpdateServiceError.rateLimited(service: url.host == "github.com" ? "GitHub" : "Mozilla")
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let finalURL = response.url, finalURL.scheme == "https", finalURL.host == url.host,
              finalURL.user == nil, finalURL.password == nil, finalURL.port == nil,
              response.expectedContentLength <= 1_048_576 else { throw CatalogError.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 1_048_576 else { throw CatalogError.invalidSize }
            data.append(byte)
        }
        try Task.checkCancellation()
        return (data, finalURL)
    }

    func parse(_ data: Data, packageIdentifier: String) throws -> CatalogDownload {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CatalogError.invalidResponse
        }
        let version: String
        let file: [String: Any]
        let address: String
        let digest: String
        switch self {
        case .mozilla:
            guard object["guid"] as? String == String(packageIdentifier.dropFirst("gecko:".count)),
                  packageIdentifier.hasPrefix("gecko:"), object["status"] as? String == "public",
                  let current = object["current_version"] as? [String: Any],
                  let number = current["version"] as? String,
                  let asset = current["file"] as? [String: Any], asset["status"] as? String == "public",
                  let url = asset["url"] as? String, let hash = asset["hash"] as? String else {
                throw CatalogError.invalidResponse
            }
            version = number; file = asset; address = url; digest = hash
        case .uBlockSafari:
            throw CatalogError.invalidResponse // Safari metadata comes from GitHubReleasePage.
        }
        guard ExtensionVersion.components(version) != nil,
              let size = file["size"] as? Int, size > 0, size <= CatalogDownload.maximumBytes,
              let url = URL(string: address), url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil, digest.hasPrefix("sha256:") else { throw CatalogError.invalidResponse }
        switch self {
        case .mozilla:
            guard url.host == "addons.mozilla.org", url.path.hasPrefix("/firefox/downloads/file/"),
                  url.pathExtension == "xpi" else { throw CatalogError.invalidResponse }
        case .uBlockSafari:
            guard url.host == "github.com",
                  url.path == "/uBlockOrigin/uBOL-home/releases/download/\(version)/uBOLite_\(version).safari.zip" else {
                throw CatalogError.invalidResponse
            }
        }
        let hash = String(digest.dropFirst(7)).lowercased()
        guard hash.count == 64, hash.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw CatalogError.invalidResponse
        }
        return CatalogDownload(version: version, url: url, sha256: hash)
    }
}

enum UpdateServiceError: LocalizedError {
    case rateLimited(service: String)
    var errorDescription: String? {
        switch self {
        case .rateLimited(let service):
            "\(service) temporarily refused update requests because its request limit was reached. Your installed extension is unaffected."
        }
    }
}

enum ExtensionVersion {
    // Curated stable releases use dotted integers. Reject unfamiliar formats rather
    // than accidentally treating a prerelease or an invalid version as an upgrade.
    static func components(_ value: String) -> [UInt64]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 8 else { return nil }
        var result: [UInt64] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let number = UInt64(part) else { return nil }
            result.append(number)
        }
        return result
    }

    static func isNewer(_ proposed: String, than installed: String) -> Bool {
        guard let lhs = components(proposed), let rhs = components(installed) else { return false }
        for i in 0..<max(lhs.count, rhs.count) {
            let a = i < lhs.count ? lhs[i] : 0
            let b = i < rhs.count ? rhs[i] : 0
            if a != b { return a > b }
        }
        return false
    }
}

@available(macOS 15.4, *)
@MainActor
final class ExtensionUpdater: ObservableObject {
    struct Candidate {
        let entry: CatalogExtension
        let download: CatalogDownload
        let installedSource: URL
    }
    struct CachedCheck: Codable {
        let checkedAt: Date
        let download: CatalogDownload?
        let error: String?

        func isFresh(at now: Date) -> Bool {
            let age = now.timeIntervalSince(checkedAt)
            return age >= 0 && age < ExtensionUpdater.checkInterval
        }
    }
    struct Preferences: Codable {
        var automaticallyInstall = true
        var lastChecked: Date?
        var cachedChecks: [String: CachedCheck]?
    }
    nonisolated static let checkInterval: TimeInterval = 4 * 60 * 60
    @Published private(set) var checking = false
    @Published private(set) var installing: UUID?
    @Published private(set) var candidates: [UUID: Candidate] = [:]
    @Published private(set) var messages: [UUID: String] = [:]
    @Published private(set) var lastChecked: Date?
    @Published var automaticallyInstall = true { didSet { savePreferences() } }
    @Published private(set) var preferenceError: String?
    private weak var manager: ExtensionManager?
    private let preferencesURL: URL
    private var timer: AnyCancellable?
    private var startupCheckPending = false
    private var cachedChecks: [String: CachedCheck] = [:]
    private(set) var task: Task<Void, Never>?
    // Injectable boundaries keep tests deterministic and off public services.
    var fetchLatest: (CatalogExtension) async throws -> CatalogDownload = {
        try await $0.updateSource.latest(packageIdentifier: $0.packageIdentifier)
    }
    var fetchPackage: (CatalogDownload) async throws -> Data = { try await $0.fetch() }

    init(manager: ExtensionManager) {
        self.manager = manager
        preferencesURL = manager.root.appendingPathComponent("update-preferences.json")
        if let data = try? Data(contentsOf: preferencesURL), let saved = try? JSONDecoder().decode(Preferences.self, from: data) {
            automaticallyInstall = saved.automaticallyInstall
            lastChecked = saved.lastChecked
            cachedChecks = saved.cachedChecks ?? [:]
        }
    }

    func start() {
        guard timer == nil else { return }
        // Restore recent results after loading extensions; only stale sources need a request.
        startupCheckPending = true
        check(force: false)
        timer = Timer.publish(every: 60, tolerance: 15, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            self?.checkIfDue()
        }
    }

    func checkIfDue(now: Date = Date()) {
        guard startupCheckPending || lastChecked == nil || now.timeIntervalSince(lastChecked!) >= Self.checkInterval else { return }
        check(force: false, now: now)
    }

    func stop() {
        timer?.cancel(); timer = nil
        task?.cancel()
    }

    func check(force: Bool = true, now: Date = Date()) {
        guard task == nil else { return }
        checking = true
        task = Task { [weak self] in
            guard let self else { return }
            defer { checking = false; task = nil }
            await manager?.restorationTask?.value
            guard let manager, !Task.isCancelled else { return }
            // Management in progress is retried by the timer without marking a check complete.
            guard !manager.busy else { return }
            let records = manager.records
            candidates = candidates.filter { id, _ in records.contains { $0.id == id } }
            var fetchedMetadata = false
            for record in records {
                guard !Task.isCancelled else { return }
                guard let entry = CatalogExtension.curated.first(where: { $0.packageIdentifier == record.packageIdentifier }),
                      let version = manager.contexts[record.id]?.webExtension.version else { continue }
                do {
                    let result: CachedCheck
                    if !force, let cached = cachedChecks[entry.id], cached.isFresh(at: now) {
                        result = cached
                    } else {
                        fetchedMetadata = true
                        do {
                            let download = try await fetchLatest(entry)
                            result = CachedCheck(checkedAt: Date(), download: download, error: nil)
                        } catch is CancellationError { return }
                        catch { result = CachedCheck(checkedAt: Date(), download: nil, error: error.localizedDescription) }
                        try Task.checkCancellation()
                        cachedChecks[entry.id] = result
                    }
                    guard let download = result.download else {
                        messages[record.id] = "Couldn’t check for updates: \(result.error ?? "No release information was returned.")"
                        continue
                    }
                    try Task.checkCancellation()
                    guard manager.records.contains(where: { $0.id == record.id && $0.source == record.source }) else { continue }
                    let migration = entry.id == "ublock-lite" && record.isBundle && download.version == version
                    if ExtensionVersion.isNewer(download.version, than: version) || migration {
                        candidates[record.id] = Candidate(entry: entry, download: download, installedSource: record.source)
                        messages[record.id] = migration ? "Ready to switch to direct Safari updates." : "Version \(download.version) is available."
                        if automaticallyInstall { await install(record.id) }
                    } else {
                        candidates[record.id] = nil
                        messages[record.id] = "Up to date."
                    }
                } catch is CancellationError { return }
                catch { messages[record.id] = "Couldn’t check for updates: \(error.localizedDescription)" }
            }
            guard !Task.isCancelled else { return }
            startupCheckPending = false
            if fetchedMetadata { lastChecked = Date() }
            savePreferences()
        }
    }

    func update(_ id: UUID) {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil }
            await install(id)
        }
    }

    private func install(_ id: UUID) async {
        guard let candidate = candidates[id], let manager else { return }
        installing = id
        defer { installing = nil }
        do {
            let data = try await fetchPackage(candidate.download)
            try Task.checkCancellation()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BendExtensionUpdate-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let package = directory.appendingPathComponent("package.\(candidate.download.url.pathExtension)")
            try await Task.detached(priority: .utility) { try data.write(to: package, options: .atomic) }.value
            try Task.checkCancellation()
            try await manager.applyCatalogUpdate(id, from: package, entry: candidate.entry,
                version: candidate.download.version, replacing: candidate.installedSource)
            candidates[id] = nil
            messages[id] = "Updated to \(candidate.download.version)." + (manager.failures[id] == nil ? "" : " Review additional permissions to enable it.")
        } catch is CancellationError { }
        catch { messages[id] = "Couldn’t update: \(error.localizedDescription)" }
    }

    private func savePreferences() {
        do {
            try FileManager.default.createDirectory(at: preferencesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Preferences(automaticallyInstall: automaticallyInstall, lastChecked: lastChecked, cachedChecks: cachedChecks))
                .write(to: preferencesURL, options: .atomic)
            preferenceError = nil
        } catch { preferenceError = "Update preferences could not be saved." }
    }
}
