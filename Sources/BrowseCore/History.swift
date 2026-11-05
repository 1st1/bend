import Foundation

public struct HistoryVisit: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let url: String
    public var title: String
    public var date: Date
}

public struct HistorySuggestion: Identifiable, Equatable, Sendable {
    public var id: String { url }
    public let url: String
    public let title: String
    public let lastVisited: Date
    public let visitCount: Int

    public var displayURL: String {
        url.replacingOccurrences(of: "^https?://", with: "", options: .regularExpression)
    }

    public func completion(for query: String) -> String? {
        guard query.count >= 2, !query.contains(where: \.isWhitespace) else { return nil }
        let candidate = query.contains("://") ? url : displayURL
        guard candidate.lowercased().hasPrefix(query.lowercased()), candidate.count > query.count else { return nil }
        return String(candidate.prefix(query.count)) == query
            ? candidate : query + candidate.dropFirst(query.count)
    }
}

private struct HistoryChoice: Codable, Equatable, Sendable {
    let query: String
    let url: String
    var weight: Double
    var date: Date
}

// @lat: [[architecture#Browsing history]]
public struct BrowsingHistory: Codable, Equatable, Sendable {
    public static let maximumVisits = 10_000
    public private(set) var visits: [HistoryVisit] = []
    private var choices: [HistoryChoice] = []

    public init() {}

    public var isValid: Bool {
        visits.count <= Self.maximumVisits && Set(visits.map(\.id)).count == visits.count
            && visits.allSatisfy { Self.webAddress($0.url) == $0.url && $0.date.timeIntervalSince1970.isFinite }
            && choices.count <= 1_000
            && choices.allSatisfy { Self.webAddress($0.url) == $0.url && $0.weight.isFinite && $0.weight > 0 }
    }

    public static func webAddress(_ address: String) -> String? {
        guard var url = URLComponents(string: address),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else { return nil }
        url.scheme = url.scheme?.lowercased()
        url.host = host.lowercased()
        url.user = nil
        url.password = nil
        return url.url?.absoluteString
    }

    @discardableResult
    public mutating func record(url: String, title: String, at date: Date = Date()) -> Bool {
        guard let url = Self.webAddress(url) else { return false }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // Reloads and duplicate callbacks within a short interval form one visit.
        if let first = visits.first, first.url == url,
           date.timeIntervalSince(first.date) >= 0, date.timeIntervalSince(first.date) < 30 {
            visits[0].date = date
            if !title.isEmpty { visits[0].title = title }
        } else {
            let index = visits.firstIndex(where: { $0.date < date }) ?? visits.endIndex
            visits.insert(HistoryVisit(id: UUID(), url: url, title: title.isEmpty ? url : title, date: date), at: index)
            if visits.count > Self.maximumVisits { visits.removeLast(visits.count - Self.maximumVisits) }
        }
        return true
    }

    public mutating func updateTitle(_ title: String, for address: String) {
        guard !title.isEmpty, let url = Self.webAddress(address),
              let index = visits.firstIndex(where: { $0.url == url }) else { return }
        visits[index].title = title
    }

    public mutating func remove(url: String) {
        visits.removeAll { $0.url == url }
        choices.removeAll { $0.url == url }
    }

    public mutating func clear() { visits.removeAll(); choices.removeAll() }

    public func matching(_ query: String) -> [HistoryVisit] {
        visits.filter { Self.matches(query, title: $0.title, url: $0.url) }
    }

    public mutating func recordChoice(url: String, query: String, at date: Date = Date()) {
        let query = Self.fold(query).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, visits.contains(where: { $0.url == url }) else { return }
        if let index = choices.firstIndex(where: { $0.url == url && $0.query == query }) {
            choices[index].weight = choices[index].weight * 0.9 + 1
            choices[index].date = date
        } else {
            choices.append(HistoryChoice(query: query, url: url, weight: 1, date: date))
        }
        choices.sort { $0.date > $1.date }
        if choices.count > 1_000 { choices.removeLast(choices.count - 1_000) }
    }

    // @lat: [[architecture#History suggestions]]
    public func suggestions(for query: String, limit: Int = 6, now: Date = Date()) -> [HistorySuggestion] {
        let query = Self.fold(query).trimmingCharacters(in: .whitespacesAndNewlines)
        let grouped = Dictionary(grouping: visits, by: \.url)
        var adaptiveScores: [String: Double] = [:]
        if !query.isEmpty {
            for choice in choices where choice.query.hasPrefix(query) {
                let score = choice.weight * (choice.query == query ? 2 : 1)
                    * pow(0.975, max(0, now.timeIntervalSince(choice.date)) / 86400)
                adaptiveScores[choice.url] = max(adaptiveScores[choice.url] ?? 0, score)
            }
        }
        let ranked = grouped.compactMap { url, visits -> (HistorySuggestion, Int, Double)? in
            guard let latest = visits.max(by: { $0.date < $1.date }),
                  Self.matches(query, title: latest.title, url: url) else { return nil }
            let suggestion = HistorySuggestion(url: url, title: latest.title, lastVisited: latest.date, visitCount: visits.count)
            let adaptive = adaptiveScores[url] ?? 0
            let components = URLComponents(string: url)
            let host = Self.fold(components?.host ?? "")
            let display = Self.fold(suggestion.displayURL)
            var match = query.isEmpty ? 0 : (host == query || Self.fold(url) == query ? 3
                : (host.hasPrefix(query) || display.hasPrefix(query) || Self.fold(url).hasPrefix(query) ? 2 : 1))
            // A host prefix should favor its visited home page over a deep link.
            let isHomePage = (components?.path.isEmpty == true || components?.path == "/")
                && components?.query == nil && components?.fragment == nil
            if isHomePage, match >= 2 { match += 1 }
            let frecency = visits.reduce(0.0) { $0 + pow(0.5, max(0, now.timeIntervalSince($1.date)) / (30 * 86400)) }
            // Learned choices help break ties, but cannot permanently override
            // stronger URL matches or an accumulating history of other visits.
            return (suggestion, match, frecency + min(6, adaptive * 3))
        }
        return ranked.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            if $0.2 != $1.2 { return $0.2 > $1.2 }
            if $0.0.lastVisited != $1.0.lastVisited { return $0.0.lastVisited > $1.0.lastVisited }
            return $0.0.url < $1.0.url
        }.prefix(max(0, limit)).map(\.0)
    }

    private static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func matches(_ query: String, title: String, url: String) -> Bool {
        let haystack = fold(title + " " + (url.removingPercentEncoding ?? url))
        return fold(query).split(whereSeparator: \.isWhitespace).allSatisfy { haystack.contains($0) }
    }
}
