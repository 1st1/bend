import Foundation

private struct Snapshot: Decodable {
    struct Visit: Decodable {
        let url: String
        let title: String
        let date: Date
    }
    let visits: [Visit]
    let choices: [HistoryChoice]
}

private struct Run: Encodable {
    let text: String
    let matched: Bool
}

private struct Result: Encodable {
    let url: String
    let address: [Run]
    let title: [Run]

    init(_ suggestion: HistorySuggestion, query: String) {
        url = suggestion.url
        let full = query.contains("://")
        let field = full ? url : suggestion.displayURL
        let decoded = field.removingPercentEncoding ?? field
        var runs = Self.runs(query, in: decoded)
        if !full {
            runs.insert(Run(text: String(url.dropLast(field.count)), matched: false), at: 0)
        }
        address = runs
        title = suggestion.title == url ? [] : Self.runs(query, in: suggestion.title)
    }

    private static func runs(_ query: String, in text: String) -> [Run] {
        let source = text as NSString
        var matches = IndexSet()
        for range in FuzzyMatch.ranges(query, in: text) {
            matches.insert(integersIn: range.location..<NSMaxRange(range))
        }
        var runs: [Run] = []
        var cursor = 0
        for range in matches.rangeView {
            if cursor < range.lowerBound {
                runs.append(Run(text: source.substring(with: NSRange(cursor..<range.lowerBound)), matched: false))
            }
            runs.append(Run(text: source.substring(with: NSRange(range)), matched: true))
            cursor = range.upperBound
        }
        if cursor < source.length {
            runs.append(Run(text: source.substring(from: cursor), matched: false))
        }
        return runs
    }
}

/// Keep one production search index alive across keystrokes, including all imported visits.
@main
enum CorpusMatcher {
    static func main() throws {
        let decoder = JSONDecoder()
        var visits: [HistoryVisit] = []
        var choices: [HistoryChoice] = []
        while let line = readLine(), !line.isEmpty {
            let snapshot = try decoder.decode(Snapshot.self, from: Data(line.utf8))
            for visit in snapshot.visits {
                guard let url = BrowsingHistory.webAddress(visit.url) else { continue }
                visits.append(HistoryVisit(id: UUID(), url: url, title: visit.title.isEmpty ? url : visit.title,
                                           date: visit.date))
            }
            choices.append(contentsOf: snapshot.choices)
        }
        let history = BrowsingHistory(visits: visits, choices: choices)
        let encoder = JSONEncoder()
        while let line = readLine() {
            let query = try decoder.decode(String.self, from: Data(line.utf8))
            let results = history.suggestions(for: query, limit: 5).map { Result($0, query: query) }
            FileHandle.standardOutput.write(try encoder.encode(results) + Data([10]))
        }
    }
}
