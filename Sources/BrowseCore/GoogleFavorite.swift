import Foundation

// @lat: [[architecture#Google account favorites]]
public enum GoogleFavoriteService: String, Sendable, CaseIterable {
    case gmail, drive, calendar

    public init?(address: String) {
        guard let url = SidebarFavorite.websiteURL(address), url.port == nil || url.port == 443 else { return nil }
        switch url.host?.lowercased() {
        case "mail.google.com": self = .gmail
        case "drive.google.com": self = .drive
        case "calendar.google.com": self = .calendar
        default: return nil
        }
    }

    public var name: String {
        switch self { case .gmail: "Gmail"; case .drive: "Google Drive"; case .calendar: "Google Calendar" }
    }

    public var home: String {
        switch self {
        case .gmail: "https://mail.google.com/mail/"
        case .drive: "https://drive.google.com/drive/"
        case .calendar: "https://calendar.google.com/calendar/"
        }
    }

    public static func normalizedEmail(_ input: String) -> String? {
        let email = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard email.utf8.count <= 254, parts.count == 2, !parts[0].isEmpty, parts[0].utf8.count <= 64,
              !parts[0].hasPrefix("."), !parts[0].hasSuffix("."), !parts[0].contains(".."),
              parts[0].allSatisfy({ "abcdefghijklmnopqrstuvwxyz0123456789.!#$%&'*+/=?^_`{|}~-".contains($0) }) else { return nil }
        let labels = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ label in
            !label.isEmpty && label.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.allSatisfy { "abcdefghijklmnopqrstuvwxyz0123456789-".contains($0) }
        }) else { return nil }
        return email
    }

    public func accountAddress(email: String) -> String {
        var url = URLComponents(string: home)!
        url.queryItems = [URLQueryItem(name: "authuser", value: email)]
        // A literal plus is commonly decoded as a form-space by Google's endpoints.
        url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return url.url!.absoluteString
    }

    public func launchAddress(email: String) -> String {
        var url = URLComponents(string: "https://accounts.google.com/AccountChooser")!
        url.queryItems = [URLQueryItem(name: "Email", value: email),
                          URLQueryItem(name: "continue", value: accountAddress(email: email))]
        url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return url.url!.absoluteString
    }

    public static func suggestedEmail(address: String) -> String? {
        guard Self(address: address) != nil, let url = URLComponents(string: address) else { return nil }
        return url.queryItems?.first(where: { $0.name == "authuser" })?.value.flatMap(normalizedEmail)
    }
}
