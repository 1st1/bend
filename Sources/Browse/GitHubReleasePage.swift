import Foundation

// @lat: [[architecture#Extension updates]]
enum GitHubReleasePage {
    static func version(from url: URL) throws -> String {
        let prefix = "/uBlockOrigin/uBOL-home/releases/tag/"
        guard url.scheme == "https", url.host == "github.com", url.port == nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.hasPrefix(prefix) else { throw CatalogError.invalidResponse }
        let version = String(url.path.dropFirst(prefix.count))
        guard ExtensionVersion.components(version) != nil else { throw CatalogError.invalidResponse }
        return version
    }

    static func download(from data: Data, version: String, packageIdentifier: String) throws -> CatalogDownload {
        guard data.count <= 1_048_576, ExtensionVersion.components(version) != nil,
              packageIdentifier == "safari:net.raymondhill.uBlock-Origin-Lite.Extension" else {
            throw CatalogError.invalidResponse
        }
        let filename = "uBOLite_\(version).safari.zip"
        let path = "/uBlockOrigin/uBOL-home/releases/download/\(version)/\(filename)"
        // Parse the asset list as HTML, without executing scripts or loading external entities.
        let document = try XMLDocument(data: data, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever])
        let rows = try document.nodes(forXPath: "//li[.//a[@href='\(path)']]")
        guard rows.count == 1 else { throw CatalogError.invalidResponse }
        // Read the visible digest in the same asset row. Foundation's HTML tidy
        // drops custom elements such as GitHub's clipboard-copy control.
        let links = try rows[0].nodes(forXPath: ".//a[contains(@href, '/releases/download/')]")
        guard links.count == 1 else { throw CatalogError.invalidResponse }
        let values = try rows[0].nodes(forXPath: ".//span[starts-with(normalize-space(text()), 'sha256:')]")
        guard values.count == 1, let digest = values[0].stringValue,
              digest.hasPrefix("sha256:") else { throw CatalogError.invalidResponse }
        let hash = String(digest.dropFirst(7)).lowercased()
        guard hash.count == 64, hash.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw CatalogError.invalidResponse
        }
        return CatalogDownload(version: version, url: URL(string: "https://github.com" + path)!, sha256: hash)
    }
}
