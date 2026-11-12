import Foundation

// @lat: [[lat.md/architecture/address-entry#Search engine preference]]
public enum SearchEngine: String, Codable, CaseIterable, Sendable {
    case google, duckDuckGo, kagi, custom

    public var name: String {
        switch self {
        case .google: "Google"
        case .duckDuckGo: "DuckDuckGo"
        case .kagi: "Kagi"
        case .custom: "Custom…"
        }
    }

    public func searchURL(for query: String, custom: CustomSearchEngine? = nil) -> URL? {
        let endpoint: String
        switch self {
        case .google: endpoint = "https://www.google.com/search"
        case .duckDuckGo: endpoint = "https://duckduckgo.com/"
        case .kagi: endpoint = "https://kagi.com/search"
        case .custom: return custom?.searchURL(for: query)
        }
        var components = URLComponents(string: endpoint)!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        // Search providers decode query strings as form data, where a bare + is a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }
}

public struct CustomSearchEngine: Codable, Equatable, Sendable {
    public var name: String
    public var template: String

    public init(name: String, template: String) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.template = template.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var validationError: String? {
        guard !name.isEmpty else { return "Enter a name for your search engine." }
        guard template.components(separatedBy: "%s").count == 2 else {
            return "Include %s exactly once where the search text belongs."
        }
        guard template.replacingOccurrences(of: "%s", with: "").range(of: "%(?![0-9A-Fa-f]{2})", options: .regularExpression) == nil,
              !template.contains(where: \.isWhitespace),
              let url = URLComponents(string: template.replacingOccurrences(of: "%s", with: "BENDSEARCHQUERY")),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else {
            return "Enter a complete HTTP or HTTPS search URL without spaces or embedded credentials."
        }
        guard !(url.host?.lowercased().contains("bendsearchquery") ?? false),
              !(url.scheme?.contains("BENDSEARCHQUERY") ?? false),
              url.fragment == nil else {
            return "Place %s in the URL path or query, without a fragment (#)."
        }
        return nil
    }

    public func searchURL(for query: String) -> URL? {
        guard validationError == nil else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: template.replacingOccurrences(of: "%s", with: encoded))
    }
}
