import Foundation

public enum PageZoom {
    public static let levels: [Double] = [0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5]

    public static func isValid(_ value: Double) -> Bool {
        value.isFinite && (0.25...5).contains(value)
    }
}

// @lat: [[architecture#Website settings]]
public struct WebsiteSettings: Equatable, Sendable {
    public var defaultZoom: Double = 1
    public var zoomByHost: [String: Double] = [:]

    public init() {}

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
        PageZoom.isValid(defaultZoom) && zoomByHost.allSatisfy { host, zoom in
            guard let url = URL(string: "https://\(host)/") else { return false }
            return Self.hostname(for: url) == host && PageZoom.isValid(zoom)
        }
    }
}
