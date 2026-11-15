import Foundation

public enum WebsitePermission: String, CaseIterable, Codable, Sendable {
    case camera, microphone, location
    public var title: String { rawValue.capitalized }

    public static func origin(for url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        let hostname = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "\(scheme)://\(hostname):\(port)"
    }
}

public enum WebsitePermissionChoice: String, CaseIterable, Sendable {
    case ask, allow, block
    public var title: String { rawValue.capitalized }
}
