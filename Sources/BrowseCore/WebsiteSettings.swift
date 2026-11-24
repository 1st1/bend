import Foundation

public enum PageZoom {
    public static let levels: [Double] = [0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5]

    public static func isValid(_ value: Double) -> Bool {
        value.isFinite && (0.25...5).contains(value)
    }
}

// @lat: [[lat.md/architecture/settings#Website settings]]
public struct WebsiteSettings: Equatable, Sendable {
    public var allowedPermissions: [String: Set<WebsitePermission>] = [:]
    public var blockedPermissions: [String: Set<WebsitePermission>] = [:]
    public var defaultZoom: Double = 1
    public var zoomByHost: [String: Double] = [:]
    public var warnFraudulentSites = true
    public var javaScriptEnabled = true
    public var warnHTTP = false
    public var allowedHTTPOrigins: Set<String> = []

    public static func httpAlternative(for url: URL) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", parts.host?.isEmpty == false,
              parts.user == nil, parts.password == nil else { return nil }
        parts.scheme = "http"
        return parts.url
    }

    public func allowsHTTP(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http", let origin = WebsitePermission.origin(for: url) else { return false }
        return allowedHTTPOrigins.contains(origin)
    }

    public func locationURL(_ input: String, searchEngine: SearchEngine, customSearchEngine: CustomSearchEngine?) -> URL? {
        guard let intent = AddressResolver.classify(input) else { return nil }
        if case .visit(let url) = intent,
           !input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("https://"),
           let http = Self.httpAlternative(for: url), allowsHTTP(http) { return http }
        return intent.destination(searchEngine: searchEngine, customSearchEngine: customSearchEngine,
                                  query: input.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    public var blockAllCookies = false
    public var preventCrossSiteTracking = true
    public var applePayDisclosureAllowed = true
    public var privateClickMeasurementEnabled = false

    public init() {}

    public func permission(_ permission: WebsitePermission, for origin: String) -> WebsitePermissionChoice {
        if blockedPermissions[origin]?.contains(permission) == true { return .block }
        if allowedPermissions[origin]?.contains(permission) == true { return .allow }
        return .ask
    }

    public var permissionOrigins: [String] {
        Set(blockedPermissions.keys).union(allowedPermissions.keys).sorted()
    }


    // Zoom is shared across paths, schemes, and ports, but not subdomains.
    public static func hostname(for url: URL) -> String? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased() else { return nil }
        var normalized = host
        while normalized.hasSuffix(".") { normalized.removeLast() }
        // Foundation versions differ on whether URL.host includes IPv6 brackets.
        if normalized.contains(":"), !normalized.hasPrefix("[") { normalized = "[\(normalized)]" }
        return normalized.isEmpty ? nil : normalized
    }

    public func zoom(for url: URL) -> Double {
        guard let host = Self.hostname(for: url) else { return 1 }
        return zoomByHost[host] ?? defaultZoom
    }

    public var isValid: Bool {
        allowedHTTPOrigins.allSatisfy { $0.hasPrefix("http://") && URL(string: $0).flatMap(WebsitePermission.origin) == $0 } &&
        allowedPermissions.keys.allSatisfy { URL(string: $0).flatMap(WebsitePermission.origin) == $0 } && blockedPermissions.keys.allSatisfy { URL(string: $0).flatMap(WebsitePermission.origin) == $0 } && PageZoom.isValid(defaultZoom) && zoomByHost.allSatisfy { host, zoom in
            guard let url = URL(string: "https://\(host)/") else { return false }
            return Self.hostname(for: url) == host && PageZoom.isValid(zoom)
        }
    }
}
