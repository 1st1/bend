import CryptoKit
import Foundation

// @lat: [[architecture#Curated extension catalog]]
struct CatalogExtension: Identifiable, Sendable {
    enum Installation: Sendable {
        case safari(bundleIdentifier: String, storeURL: URL)
        case download(CatalogDownload)
    }

    let id: String
    let name: String
    let publisher: String
    let category: String
    let summary: String
    let compatibility: String
    let experimental: Bool
    let symbol: String
    let packageIdentifier: String
    let website: URL
    let installation: Installation

    func matches(_ query: String) -> Bool {
        query.split(whereSeparator: \.isWhitespace).allSatisfy { word in
            [name, publisher, category, summary].contains { $0.localizedCaseInsensitiveContains(word) }
        }
    }

    static let curated: [CatalogExtension] = [
        .init(id: "ublock-lite", name: "uBlock Origin Lite", publisher: "Raymond Hill", category: "Privacy",
            summary: "Block ads and trackers with lightweight, built-in filter lists.",
            compatibility: "Blocking reported working in Browse with the Safari package. Advanced filtering and site-specific behavior may vary.",
            experimental: false, symbol: "shield.lefthalf.filled",
            packageIdentifier: "safari:net.raymondhill.uBlock-Origin-Lite.Extension",
            website: URL(string: "https://github.com/uBlockOrigin/uBOL-home")!,
            installation: .safari(bundleIdentifier: "net.raymondhill.uBlock-Origin-Lite.Extension",
                storeURL: URL(string: "https://apps.apple.com/app/ublock-origin-lite/id6745342698")!)),
        .init(id: "1password", name: "1Password", publisher: "1Password", category: "Passwords",
            summary: "Keep passwords and vault items close at hand as you browse.",
            compatibility: "Sign in directly to your 1Password account. Vault items have been confirmed in Browse; autofill still needs testing. Desktop-app unlock is unavailable. Use this version instead of 1Password for Safari.",
            experimental: true, symbol: "key.fill",
            packageIdentifier: "gecko:{d634138d-c276-4fc8-924b-40a0ea21d284}",
            website: URL(string: "https://addons.mozilla.org/firefox/addon/1password-x-password-manager/")!,
            installation: .download(.init(version: "8.12.41.1",
                url: URL(string: "https://addons.mozilla.org/firefox/downloads/file/5097307/1password_x_password_manager-8.12.41.1.xpi")!,
                sha256: "6b00acff73253865303af49e99329245a940348484cbd931ea39f9fa215134f5")))
    ]
}

struct CatalogDownload: Sendable {
    let version: String
    let url: URL
    let sha256: String
    static let maximumBytes = 64 * 1024 * 1024

    func validate(_ data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.url?.scheme == "https" else { throw CatalogError.invalidResponse }
        guard !data.isEmpty, data.count <= Self.maximumBytes else { throw CatalogError.invalidSize }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == sha256 else { throw CatalogError.checksumMismatch }
    }

    func fetch() async throws -> Data {
        guard url.scheme == "https" else { throw CatalogError.invalidResponse }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.url?.scheme == "https" else { throw CatalogError.invalidResponse }
        guard response.expectedContentLength <= Self.maximumBytes else { throw CatalogError.invalidSize }
        var data = Data()
        for try await byte in bytes {
            if data.count % 65_536 == 0 { try Task.checkCancellation() }
            guard data.count < Self.maximumBytes else { throw CatalogError.invalidSize }
            data.append(byte)
        }
        try Task.checkCancellation()
        try validate(data, response: response)
        return data
    }
}

enum CatalogError: LocalizedError {
    case invalidResponse, invalidSize, checksumMismatch
    var errorDescription: String? {
        switch self {
        case .invalidResponse: "The extension download failed. Try again later."
        case .invalidSize: "The extension download is empty or too large. Nothing was installed."
        case .checksumMismatch: "The download does not match the reviewed package. Nothing was installed."
        }
    }
}
