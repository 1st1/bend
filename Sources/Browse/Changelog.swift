import Foundation
import Markdown

// @lat: [[lat.md/architecture/updates#What's New page]]
struct Changelog: Sendable {
    struct Release: Identifiable, Sendable {
        let version: String
        let markdown: String
        let date: Date?
        var id: String { version }
    }
    let releases: [Release]

    init(markdown: String, releaseDates: [String: String] = [:]) {
        let lines = markdown.components(separatedBy: "\n")
        let headings = Document(parsing: markdown).children.compactMap { node -> (String, Int)? in
            guard let heading = node as? Heading, heading.level == 2,
                  let line = heading.range?.lowerBound.line else { return nil }
            let title = heading.plainText
            let version = title.hasPrefix("v") ? String(title.dropFirst()) : title
            guard InstalledRelease.validVersion(version) else { return nil }
            return (version, line - 1)
        }
        releases = headings.enumerated().map { index, heading in
            let end = index + 1 < headings.count ? headings[index + 1].1 : lines.count
            return Release(version: heading.0, markdown: lines[(heading.1 + 1)..<end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
                           date: Self.releaseDate(releaseDates[heading.0]))
        }
    }

    private static func releaseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else { return nil }
        return date
    }

    static func load(bundle: Bundle = .main) -> Changelog {
        let source = bundle.url(forResource: "CHANGELOG", withExtension: "md")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let dates = bundle.url(forResource: "release-dates", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        return Changelog(markdown: source, releaseDates: dates)
    }
}

struct InstalledRelease: Equatable {
    let version: String
    let build: String

    static func validVersion(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 3 && parts.allSatisfy { validNumber(String($0)) }
    }
    private static func validNumber(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) } && (value == "0" || !value.hasPrefix("0"))
    }
    init?(version: String?, build: String?) {
        guard let version, let build, Self.validVersion(version), Self.validNumber(build) else { return nil }
        self.version = version; self.build = build
    }
    func isNewer(than other: InstalledRelease) -> Bool {
        let versions = version.compare(other.version, options: .numeric)
        return versions == .orderedDescending || (versions == .orderedSame && build.compare(other.build, options: .numeric) == .orderedDescending)
    }
}

// @lat: [[lat.md/architecture/updates#Post-update release notes]]
struct WhatsNewTracker {
    static let preferenceKey = "updates.lastLaunchedRelease"
    let defaults: UserDefaults
    let current: InstalledRelease?
    let enabled: Bool

    init(profile: AppProfile = .current, bundle: Bundle = .main, defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? profile.defaults
        enabled = profile == .production && bundle.bundleIdentifier == profile.bundleIdentifier && bundle.bundleURL.pathExtension == "app"
        current = InstalledRelease(version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                                   build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
    }

    /// A newer running bundle is evidence of installation, independent of whether
    /// Sparkle or a manual replacement installed it. Keep a high-water mark on rollback.
    func consumeUpgrade() -> Bool {
        guard enabled, let current else { return false }
        let saved = defaults.dictionary(forKey: Self.preferenceKey)
        let previous = InstalledRelease(version: saved?["version"] as? String, build: saved?["build"] as? String)
        guard previous == nil || current.isNewer(than: previous!) else { return false }
        defaults.set(["version": current.version, "build": current.build], forKey: Self.preferenceKey)
        return previous != nil
    }
}
