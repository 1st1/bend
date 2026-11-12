import Foundation

// @lat: [[lat.md/architecture/favorites#Sidebar favorites]]
public struct SidebarFavorite: Codable, Identifiable, Sendable {
    public static let limit = 9
    public let id: UUID
    public var address: String
    public let title: String
    public var iconPNG: Data?
    public var googleAccountEmail: String?

    public var launchAddress: String {
        guard let email = googleAccountEmail, GoogleFavoriteService.normalizedEmail(email) == email,
              let service = GoogleFavoriteService(address: address) else { return address }
        return service.launchAddress(email: email)
    }

    public init(address: String, title: String, iconPNG: Data? = nil) {
        id = UUID()
        self.address = address
        self.title = String(title.prefix(512))
        self.iconPNG = iconPNG
    }

    public static func websiteURL(_ address: String) -> URL? {
        guard let url = URL(string: address), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }

    public static func validated(_ favorites: [Self]) -> [Self] {
        var ids = Set<UUID>(), addresses = Set<String>()
        return Array(favorites.filter {
            websiteURL($0.address) != nil && ($0.iconPNG?.count ?? 0) <= 65_536
                && ids.insert($0.id).inserted && addresses.insert($0.address).inserted
        }.prefix(limit))
    }
}
