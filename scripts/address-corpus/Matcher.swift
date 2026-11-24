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
    let score: HistoryMatchScore?
    let historyURL: String?
    let detail: [Run]
    let title: [Run]

    init(_ row: AddressSuggestions.Row, query: String) {
        score = row.score
        historyURL = row.history?.url
        let highlight = historyURL == nil ? "" : query
        detail = Self.runs(highlight, in: row.detail)
        title = Self.runs(highlight, in: row.title)
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

private struct CorpusInput: Decodable {
    let snapshots: [Snapshot]
    let searchEngine: SearchEngine?
    let customSearchEngine: CustomSearchEngine?
}

private struct Reply: Encodable {
    let rows: [Result]
    let selected: Int
    let completion: String?
}

/// One Swift index per Python matcher. Only opaque handles and UTF-8 JSON cross the C ABI.
private final class CorpusMatcher {
    let history: BrowsingHistory
    let engine: SearchEngine
    let custom: CustomSearchEngine?

    init(_ input: CorpusInput) {
        var visits: [HistoryVisit] = []
        var choices: [HistoryChoice] = []
        for snapshot in input.snapshots {
            for visit in snapshot.visits {
                guard let url = BrowsingHistory.webAddress(visit.url) else { continue }
                visits.append(HistoryVisit(id: UUID(), url: url, title: visit.title.isEmpty ? url : visit.title,
                                           date: visit.date))
            }
            choices.append(contentsOf: snapshot.choices)
        }
        history = BrowsingHistory(visits: visits, choices: choices)
        engine = input.searchEngine ?? .google
        custom = input.customSearchEngine
    }
}

@_cdecl("bend_corpus_create")
public func corpusCreate(_ json: UnsafePointer<CChar>) -> UnsafeMutableRawPointer? {
    guard let input = try? JSONDecoder().decode(CorpusInput.self, from: Data(String(cString: json).utf8)) else { return nil }
    return Unmanaged.passRetained(CorpusMatcher(input)).toOpaque()
}

@_cdecl("bend_corpus_query")
public func corpusQuery(_ handle: UnsafeMutableRawPointer, _ text: UnsafePointer<CChar>, _ autofill: Int32) -> UnsafeMutablePointer<CChar>? {
    let matcher = Unmanaged<CorpusMatcher>.fromOpaque(handle).takeUnretainedValue()
    let query = String(cString: text)
    let model = AddressSuggestions(history: matcher.history, typedQuery: query, allowAutofill: autofill != 0,
                                   searchEngine: matcher.engine, customSearchEngine: matcher.custom)
    let reply = Reply(rows: model.rows.map { Result($0, query: query) }, selected: model.selected, completion: model.completion)
    guard let data = try? JSONEncoder().encode(reply) else { return nil }
    return strdup(String(decoding: data, as: UTF8.self))
}

@_cdecl("bend_corpus_free_reply")
public func corpusFreeReply(_ reply: UnsafeMutablePointer<CChar>) { free(reply) }

@_cdecl("bend_corpus_destroy")
public func corpusDestroy(_ handle: UnsafeMutableRawPointer) { Unmanaged<CorpusMatcher>.fromOpaque(handle).release() }
