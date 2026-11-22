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
    public var isFuzzyMatch = false
    public var isPathMatch = false

    public var displayURL: String {
        url.replacingOccurrences(of: "^https?://", with: "", options: .regularExpression)
    }

    public func completion(for query: String) -> String? {
        guard query.count >= 2, !query.contains(where: \.isWhitespace) else { return nil }
        let candidate = query.contains("://") ? url : displayURL
        guard candidate.count > query.count, candidate.lowercased().hasPrefix(query.lowercased()) else { return nil }
        return String(candidate.prefix(query.count)) == query
            ? candidate : query + candidate.dropFirst(query.count)
    }
}

struct HistoryChoice: Codable, Equatable, Sendable {
    let query: String
    let url: String
    var weight: Double
    var date: Date
}

// @lat: [[lat.md/architecture/history#Browsing history]]
public struct BrowsingHistory: Codable, Equatable, Sendable {
    public static let maximumVisits = 10_000
    public private(set) var visits: [HistoryVisit] = []
    var choices: [HistoryChoice] = []

    // Derived data belongs to this snapshot and never enters SQLite or legacy JSON.
    private struct SearchText: Sendable {
        let title: FuzzyMatch.Candidate
        let fullURL: FuzzyMatch.Candidate
        let displayURL: FuzzyMatch.Candidate
        let literal: String
        let asciiLiteral: Data?
        let foldedURL: String
        let host: String
        let display: String
        let pathGroups: [String]
        let ipv4: Bool
        let homePage: Bool

        init(_ suggestion: HistorySuggestion) {
            let url = suggestion.url
            let components = URLComponents(string: url)
            let displayURL = suggestion.displayURL
            title = FuzzyMatch.Candidate(suggestion.title)
            self.displayURL = FuzzyMatch.Candidate(displayURL.removingPercentEncoding ?? displayURL)
            let decodedURL = url.removingPercentEncoding ?? url
            fullURL = FuzzyMatch.Candidate(decodedURL)
            literal = fold(suggestion.title + " " + decodedURL)
            asciiLiteral = literal.utf8.allSatisfy { $0 < 128 } ? Data(literal.utf8) : nil
            foldedURL = fold(url)
            host = fold(components?.host ?? "")
            display = fold(displayURL)
            // Split before decoding so an escaped slash stays inside its path component.
            let path = components?.percentEncodedPath.prefix(2048) ?? ""
            pathGroups = [host] + path.split(separator: "/").map { fold($0.removingPercentEncoding ?? String($0)) }
            ipv4 = isIPv4(components?.host ?? "", partial: false)
            homePage = (components?.path.isEmpty == true || components?.path == "/")
                && components?.query == nil && components?.fragment == nil
        }
    }

    private struct SearchRecord: Sendable {
        let suggestion: HistorySuggestion
        let text: SearchText
        let dates: [Date]

        init(visits: [HistoryVisit], latest: HistoryVisit, reusing previous: SearchRecord? = nil) {
            suggestion = HistorySuggestion(url: latest.url, title: latest.title, lastVisited: latest.date, visitCount: visits.count)
            if let previous, previous.suggestion.title.utf8.elementsEqual(latest.title.utf8) {
                text = previous.text
            } else {
                text = SearchText(suggestion)
            }
            dates = visits.map(\.date)
        }
    }

    private var records: [String: SearchRecord] = [:]
    private enum CodingKeys: String, CodingKey { case visits, choices }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(visits: container.decode([HistoryVisit].self, forKey: .visits),
                      choices: container.decode([HistoryChoice].self, forKey: .choices))
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.visits == rhs.visits && lhs.choices == rhs.choices
    }

    public init() {}

    init(visits: [HistoryVisit], choices: [HistoryChoice]) {
        self.visits = visits
        self.choices = choices
        rebuildRecords()
    }

    private mutating func rebuildRecords() {
        records = Dictionary(grouping: visits, by: \.url).compactMapValues { group in
            guard let latest = group.max(by: { $0.date < $1.date }) else { return nil }
            return SearchRecord(visits: group, latest: latest, reusing: records[latest.url])
        }
    }

    private mutating func refreshRecord(for url: String) {
        let group = visits.filter { $0.url == url }
        if let latest = group.max(by: { $0.date < $1.date }) {
            records[url] = SearchRecord(visits: group, latest: latest, reusing: records[url])
        } else {
            records.removeValue(forKey: url)
        }
    }

    public var isValid: Bool {
        visits.count <= Self.maximumVisits && Set(visits.map(\.id)).count == visits.count
            && visits.allSatisfy { Self.webAddress($0.url) == $0.url && $0.date.timeIntervalSince1970.isFinite }
            && choices.count <= 1_000
            && Set(choices.map { [$0.query, $0.url] }).count == choices.count
            && choices.allSatisfy { Self.webAddress($0.url) == $0.url && $0.weight.isFinite && $0.weight > 0
                && $0.date.timeIntervalSince1970.isFinite }
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
            if visits.count <= Self.maximumVisits, records[url] == nil {
                let visit = visits[index]
                records[url] = SearchRecord(visits: [visit], latest: visit)
                return true
            }
            if visits.count > Self.maximumVisits {
                let evicted = visits.suffix(from: Self.maximumVisits).map(\.url)
                visits.removeLast(evicted.count)
                for removed in Set(evicted) where removed != url { refreshRecord(for: removed) }
            }
        }
        refreshRecord(for: url)
        return true
    }

    public mutating func updateTitle(_ title: String, for address: String) {
        guard !title.isEmpty, let url = Self.webAddress(address),
              let index = visits.firstIndex(where: { $0.url == url }) else { return }
        visits[index].title = title
        refreshRecord(for: url)
    }

    public mutating func remove(url: String) {
        visits.removeAll { $0.url == url }
        choices.removeAll { $0.url == url }
        records.removeValue(forKey: url)
    }

    public mutating func clear(since cutoff: Date) {
        visits.removeAll { $0.date >= cutoff }
        rebuildRecords()
        let retained = records.keys
        choices.removeAll { $0.date >= cutoff || !retained.contains($0.url) }
    }

    public mutating func clear() { visits.removeAll(); choices.removeAll(); records.removeAll() }

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

    /// Host-only input can be a partial domain. Numeric dotted searches have separate IPv4 rules.
    private static func isDomainQuery(_ query: String) -> Bool {
        var host = query[...]
        for scheme in ["https://", "http://"] where host.lowercased().hasPrefix(scheme) {
            host = host.dropFirst(scheme.count)
            break
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.last?.first?.isLetter == true else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.first != "-" && label.last != "-" &&
                label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }

    /// A dot advances to the next hostname label even when the previous label is incomplete.
    private static func matchesHostLabels(_ prefixes: [Substring], host: String) -> Bool {
        guard let first = prefixes.first else { return false }
        let labels = host.split(separator: ".")
        guard prefixes.count <= labels.count else { return false }
        for start in 0...(labels.count - prefixes.count) where labels[start].hasPrefix(first) {
            if zip(labels.dropFirst(start), prefixes).allSatisfy({ $0.hasPrefix($1) }) { return true }
        }
        return false
    }

    private struct PathQuery {
        let groups: [FuzzyMatch.Word]
        let scheme: String?
        let hostPrefixes: [Substring]

        init?(_ word: String) {
            let scheme = ["https://", "http://"].first(where: { word.hasPrefix($0) })
            let path = word.dropFirst(scheme?.count ?? 0)
            guard path.count <= 128, !path.contains("?"), !path.contains("#") else { return nil }
            let groups = path.split(separator: "/")
            guard groups.count >= 2 else { return nil }
            self.groups = groups.map { FuzzyMatch.Word(String($0)) }
            hostPrefixes = groups.first.map { isDomainQuery(String($0)) ? $0.split(separator: ".") : [] } ?? []
            self.scheme = scheme
        }

        /// Every slash advances exactly one component, starting at the hostname.
        func matchesLeadingComponents(_ components: [String]) -> Bool {
            guard groups.count <= components.count, let first = groups.first, let host = components.first,
                  host.hasPrefix(first.text) || matchesHostLabels(hostPrefixes, host: host) else { return false }
            return zip(groups.dropFirst(), components.dropFirst()).allSatisfy { $1.hasPrefix($0.text) }
        }

        /// Best ordered assignment of query groups to distinct host or path components.
        func score(in components: [String], anchored: Bool) -> Int? {
            guard groups.count <= components.count else { return nil }
            if anchored {
                // Score the components actually typed, so /1 cannot jump forward to /photo/1.
                var score = 8
                for (group, component) in zip(groups, components) {
                    score += component == group.text ? 100 : 70
                }
                return score + (groups.count == components.count ? 6 : 0)
            }
            var previous = [Int?](repeating: nil, count: components.count)
            for (row, group) in groups.enumerated() {
                var current = [Int?](repeating: nil, count: components.count)
                var preceding: Int?
                for (index, component) in components.enumerated() {
                    if index > 0 {
                        // Moving one component farther costs four points per skipped component.
                        preceding = preceding.map { $0 - 4 }
                        if let adjacent = previous[index - 1], adjacent > (preceding ?? Int.min) {
                            preceding = adjacent
                        }
                    }
                    guard let start = row == 0 ? 0 : preceding else { continue }
                    let quality: Int
                    if component == group.text { quality = 100 }
                    else if component.hasPrefix(group.text) { quality = 70 }
                    else if row == 0, index == 0, matchesHostLabels(hostPrefixes, host: component) { quality = 65 }
                    else if component.contains(group.text) { quality = 45 }
                    else if let first = group.pattern.first, component.contains(first),
                            group.qualifiedScore(in: FuzzyMatch.Candidate(component)) != nil { quality = 25 }
                    else { continue }
                    let hostBonus = index == 0 ? 8 : 0
                    let finalBonus = row == groups.count - 1 && index == components.count - 1 ? 6 : 0
                    current[index] = start + quality + hostBonus + finalBonus
                }
                guard current.contains(where: { $0 != nil }) else { return nil }
                previous = current
            }
            return previous.compactMap { $0 }.max()
        }
    }

    // @lat: [[lat.md/architecture/history#History suggestions]]
    public func suggestions(for query: String, limit: Int = 6, now: Date = Date()) -> [HistorySuggestion] {
        let query = Self.fold(query).trimmingCharacters(in: .whitespacesAndNewlines)
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let addressQuery = query.replacingOccurrences(of: "^https?://", with: "", options: .regularExpression)
        let queryHost = String(addressQuery.prefix { !"/:?#".contains($0) })
        let ipv4Prefix = Self.isIPv4(queryHost, partial: true) && !query.contains(where: \.isWhitespace)
        let domainQuery = Self.isDomainQuery(query)
        let hostPrefixes = queryHost.split(separator: ".")
        let onlyHost = addressQuery == queryHost || addressQuery == queryHost + "/"
        let hasScheme = query.contains("://")
        let preparedWords = words.map(FuzzyMatch.Word.init)
        let pathQuery = words.first.flatMap(PathQuery.init)
        let fuzzyWords = words.joined().count <= 128 ? preparedWords : []
        var adaptiveScores: [String: Double] = [:]
        if !query.isEmpty {
            for choice in choices where choice.query.hasPrefix(query) {
                let score = choice.weight * (choice.query == query ? 2 : 1)
                    * pow(0.975, max(0, now.timeIntervalSince(choice.date)) / 86400)
                adaptiveScores[choice.url] = max(adaptiveScores[choice.url] ?? 0, score)
            }
        }
        let ranked = records.values.compactMap { record -> (HistorySuggestion, Int, Int, Double)? in
            var suggestion = record.suggestion
            let text = record.text
            if ipv4Prefix {
                guard text.ipv4, (hasScheme ? text.foldedURL : text.display).hasPrefix(query) else { return nil }
            } else if domainQuery {
                let prefixMatches = hasScheme ? text.foldedURL.hasPrefix(query)
                    : text.host.hasPrefix(query)
                if !prefixMatches {
                    guard (!hasScheme || text.foldedURL.hasPrefix(query.prefix { $0 != ":" } + "://")),
                          Self.matchesHostLabels(hostPrefixes, host: text.host) else { return nil }
                    suggestion.isFuzzyMatch = true
                }
            }
            let literal = ipv4Prefix || domainQuery || preparedWords.allSatisfy { word in
                if let haystack = text.asciiLiteral, let needle = word.asciiData {
                    return haystack.range(of: needle) != nil
                }
                return text.literal.contains(word.text)
            }
            var fuzzy = 0
            var pathTier = 0
            if let pathQuery {
                if let scheme = pathQuery.scheme, !text.foldedURL.hasPrefix(scheme) { return nil }
                let addressPrefix = text.display.hasPrefix(query) || text.foldedURL.hasPrefix(query)
                let anchored = addressPrefix || pathQuery.matchesLeadingComponents(text.pathGroups)
                if let groupScore = pathQuery.score(in: text.pathGroups, anchored: anchored) {
                    pathTier = addressPrefix ? 7 : (anchored ? 6 : 5)
                    let extraWords = Array(preparedWords.dropFirst())
                    if extraWords.isEmpty {
                        fuzzy = groupScore
                    } else {
                        guard !fuzzyWords.isEmpty, let score = FuzzyMatch.score(words: extraWords, title: text.title, url: text.displayURL)
                        else { return nil }
                        fuzzy = groupScore + score
                    }
                    suggestion.isPathMatch = true
                    suggestion.isFuzzyMatch = !literal
                } else if !literal { return nil }
            } else if !literal {
                let url = hasScheme ? text.fullURL : text.displayURL
                guard let score = FuzzyMatch.score(words: fuzzyWords, title: text.title, url: url) else { return nil }
                fuzzy = score
                suggestion.isFuzzyMatch = true
            }
            if domainQuery && suggestion.isFuzzyMatch && text.homePage { fuzzy = 1 }
            let adaptive = adaptiveScores[suggestion.url] ?? 0
            var match = 0
            if literal && !suggestion.isFuzzyMatch && !query.isEmpty {
                if text.host == query || text.foldedURL == query {
                    match = 3
                } else if text.host.hasPrefix(query) || text.display.hasPrefix(query)
                    || text.foldedURL.hasPrefix(query) {
                    match = 2
                } else {
                    match = 1
                }
                if match == 1, onlyHost, !hasScheme, Self.matchesHostLabels(hostPrefixes, host: text.host) {
                    match = 2
                }
                if text.homePage, match >= 2 { match += 1 }
            }
            let frecency = record.dates.reduce(0.0) { $0 + pow(0.5, max(0, now.timeIntervalSince($1)) / (30 * 86400)) }
            // Learned choices help break ties, but cannot permanently override
            // stronger URL matches or an accumulating history of other visits.
            if suggestion.isPathMatch { match = pathTier }
            return (suggestion, match, fuzzy, frecency + min(6, adaptive * 3))
        }
        return ranked.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            if $0.2 != $1.2 { return $0.2 > $1.2 }
            if $0.3 != $1.3 { return $0.3 > $1.3 }
            if $0.0.lastVisited != $1.0.lastVisited { return $0.0.lastVisited > $1.0.lastVisited }
            return $0.0.url < $1.0.url
        }.prefix(max(0, limit)).map(\.0)
    }

    private static func isIPv4(_ host: String, partial: Bool) -> Bool {
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard partial ? (2...4).contains(octets.count) : octets.count == 4 else { return false }
        return octets.enumerated().allSatisfy { index, octet in
            if partial && index == octets.count - 1 && octet.isEmpty { return true }
            return (1...3).contains(octet.count)
                && octet.utf8.allSatisfy { (48...57).contains($0) }
                && Int(octet).map { $0 <= 255 } == true
        }
    }

    private static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private static func matches(_ query: String, title: String, url: String) -> Bool {
        let haystack = fold(title + " " + (url.removingPercentEncoding ?? url))
        return fold(query).split(whereSeparator: \.isWhitespace).allSatisfy { haystack.contains($0) }
    }
}
