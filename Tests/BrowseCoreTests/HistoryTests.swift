import Foundation
import Testing
@testable import BrowseCore

private let historyNow = Date(timeIntervalSince1970: 1_800_000_000)

// @lat: [[lat.md/tests/history-tests#Fuzzy address matching]]
@Test func fuzzyAddressMatching() throws {
    var history = BrowsingHistory()
    let jit = "https://github.com/1st1/jit"
    let loose = "https://github.com/another/project/just-in-time"
    history.record(url: jit, title: "JIT compiler", at: historyNow.addingTimeInterval(-86400))
    for index in 0..<20 {
        history.record(url: loose, title: "Compiler", at: historyNow.addingTimeInterval(Double(-index * 60)))
    }
    for query in ["github/jit", "GITHUB/JIT", "gh/jit", "https://github/jit", "gh/jit compiler"] {
        let results = history.suggestions(for: query, now: historyNow)
        #expect(results.first?.url == jit)
        #expect(results.first?.isFuzzyMatch == true)
        #expect(results.first?.completion(for: query) == nil)
    }
    let suffix = "https://github.com/1st1/jit-lat"
    for index in 0..<22 {
        history.record(url: suffix, title: "1st1/jit-lat", at: historyNow.addingTimeInterval(Double(-index * 60)))
    }
    #expect(history.suggestions(for: "gh/jit", now: historyNow).first?.url == jit)
    #expect(history.suggestions(for: "gh/jit-l", now: historyNow).first?.url == suffix)
    #expect(try #require(FuzzyMatch.score("gh/jit", in: "github.com/1st1/jit"))
        > #require(FuzzyMatch.score("gh/jit", in: "github.com/1st1/jit-lat")))
    #expect(history.suggestions(for: "github/jit", now: historyNow).contains { $0.url == loose })
    #expect(history.suggestions(for: "github/zzzz", now: historyNow).isEmpty)
    #expect(history.suggestions(for: "tij/buhtig", now: historyNow).isEmpty)
    var noise = BrowsingHistory()
    let election = "https://www.nytimes.com/interactive/2026/11/03/us/elections/results-alaska-us-senate.html"
    noise.record(url: election, title: "Alaska U.S. Senate 2026: Live Midterm Election Results, Sullivan vs. Peltola - The New York Times", at: historyNow)
    for query in ["karpathy mini ll", "karpathy mini", "mini ll"] {
        #expect(noise.suggestions(for: query, now: historyNow).isEmpty)
    }
    // A literal word must not rescue another word's weak subsequence.
    noise.record(url: "https://example.com/", title: "Karpathy mxxxxixxxxnxxxxi", at: historyNow)
    #expect(noise.suggestions(for: "karpathy mini", now: historyNow).isEmpty)
    noise.record(url: "https://example.com/karpathy/mini-llm", title: "Karpathy mini LLM", at: historyNow)
    #expect(noise.suggestions(for: "karpathy mini ll", now: historyNow).first?.url == "https://example.com/karpathy/mini-llm")
    noise.record(url: "https://example.com/errors", title: "NullPointerException", at: historyNow)
    #expect(noise.suggestions(for: "npe", now: historyNow).contains { $0.title == "NullPointerException" })
    let literal = "https://example.com/github/jit"
    history.record(url: literal, title: "Literal", at: historyNow.addingTimeInterval(-86400 * 60))
    #expect(history.suggestions(for: "github/jit", now: historyNow).first?.url == literal)
    #expect(history.suggestions(for: "github/jit", now: historyNow).first?.isFuzzyMatch == false)
    #expect(history.suggestions(for: "github/jit", limit: 1, now: historyNow).count == 1)
    #expect(history.suggestions(for: "github/jit", limit: 0, now: historyNow).isEmpty)
    #expect(try #require(FuzzyMatch.score("npe", in: "NullPointerException")) > #require(FuzzyMatch.score("npe", in: "nullpointerexception")))
    #expect(FuzzyMatch.score("cfe", in: "Café") != nil)
    #expect(FuzzyMatch.score("東京", in: "東の京") != nil)
    #expect(FuzzyMatch.score("aab", in: "ab") == nil)
    #expect(FuzzyMatch.score(String(repeating: "a", count: 129), in: String(repeating: "a", count: 200)) == nil)
    #expect(FuzzyMatch.score("z", in: String(repeating: "a", count: 2048) + "z") == nil)
    history.remove(url: jit)
    #expect(!history.suggestions(for: "gh/jit", now: historyNow).contains { $0.url == jit })
}

// @lat: [[lat.md/tests/history-tests#History recording]]
@Test func historyRecording() throws {
    var history = BrowsingHistory()
    let internalPage = history.record(url: "bend://history", title: "History")
    let localFile = history.record(url: "file:///tmp/private", title: "File")
    #expect(!internalPage)
    #expect(!localFile)
    history.record(url: "https://user:secret@example.com/path?q=one#section", title: "First", at: historyNow)
    #expect(history.visits[0].url == "https://example.com/path?q=one#section")
    let id = history.visits[0].id
    history.record(url: history.visits[0].url, title: "Updated", at: historyNow.addingTimeInterval(5))
    #expect(history.visits.count == 1)
    #expect(history.visits[0].id == id)
    #expect(history.visits[0].title == "Updated")
    history.record(url: history.visits[0].url, title: "Again", at: historyNow.addingTimeInterval(60))
    #expect(history.visits.count == 2)
    history.updateTitle("Final title", for: history.visits[0].url)
    #expect(history.visits[0].title == "Final title")
    #expect(history.visits.count == 2)
    let restored = try JSONDecoder().decode(BrowsingHistory.self, from: JSONEncoder().encode(history))
    #expect(restored == history)
    #expect(restored.isValid)
    #expect(restored.suggestions(for: "final title").first?.visitCount == 2)
    history.clear(since: historyNow.addingTimeInterval(30))
    #expect(history.suggestions(for: "final title").isEmpty)
    #expect(history.suggestions(for: "updated").first?.visitCount == 1)
    #expect(restored.suggestions(for: "final title").first?.visitCount == 2)
}

// @lat: [[lat.md/tests/history-tests#History matching and completion]]
@Test func historyMatchingAndCompletion() {
    var history = BrowsingHistory()
    history.record(url: "https://example.com/creme%20brulee", title: "Café recipes", at: historyNow)
    #expect(history.matching("CAFE example").count == 1)
    #expect(history.matching("brulee recipes").count == 1)
    #expect(history.matching("cafe missing").isEmpty)
    let suggestion = history.suggestions(for: "example", now: historyNow).first!
    #expect(suggestion.completion(for: "exa") == "example.com/creme%20brulee")
    #expect(suggestion.completion(for: "https://exa") == suggestion.url)
    #expect(suggestion.completion(for: "cafe recipes") == nil)
    #expect(suggestion.completion(for: "e") == nil)
    #expect(suggestion.completion(for: suggestion.displayURL) == nil)

    history.record(url: "https://www.nytimes.com/", title: "The New York Times", at: historyNow)
    let times = history.suggestions(for: "nytim", now: historyNow).first!
    #expect(times.completion(for: "nytim") == "nytimes.com/")
    #expect(times.completion(for: "WWW.NYtim") == "WWW.NYtimes.com/")
    #expect(times.completion(for: "www.nytim") == "www.nytimes.com/")
    #expect(times.completion(for: "https://www.nytim") == times.url)
    #expect(times.completion(for: "https://nytim") == nil)
    #expect(times.completion(for: "nytimes.com/") == nil)
    #expect(times.url == "https://www.nytimes.com/")
    history.record(url: "https://news.example.com/", title: "News", at: historyNow)
    #expect(history.suggestions(for: "news.example", now: historyNow).first?.completion(for: "example") == nil)
}

// @lat: [[lat.md/tests/history-tests#History ranking and learned choices]]
@Test func historyRanking() {
    var history = BrowsingHistory()
    let recent = "https://recent.example.com/"
    let frequent = "https://frequent.example.com/"
    let old = "https://old.example.com/"
    history.record(url: old, title: "Docs old", at: historyNow.addingTimeInterval(-86400 * 180))
    history.record(url: recent, title: "Docs recent", at: historyNow)
    #expect(history.suggestions(for: "docs", now: historyNow).first?.url == recent)
    for day in 1...3 {
        history.record(url: frequent, title: "Docs frequent", at: historyNow.addingTimeInterval(Double(-86400 * day)))
    }
    #expect(history.suggestions(for: "docs", now: historyNow).first?.url == frequent)
    #expect(history.suggestions(for: "docs", now: historyNow).first?.visitCount == 3)
    history.recordChoice(url: recent, query: "docs", at: historyNow)
    #expect(history.suggestions(for: "docs", now: historyNow).first?.url == recent)
    #expect(history.suggestions(for: "DOC", now: historyNow).first?.url == recent)
    #expect(history.suggestions(for: "frequent.example.com", now: historyNow).first?.url == frequent)
    #expect(history.suggestions(for: "", limit: 1, now: historyNow).count == 1)
    #expect(history.suggestions(for: "", limit: 0, now: historyNow).isEmpty)
}

// @lat: [[lat.md/tests/history-tests#History removal and bounds]]
@Test func historyRemovalAndBounds() {
    var history = BrowsingHistory()
    for index in 0...BrowsingHistory.maximumVisits {
        history.record(url: "https://example.com/\(index)", title: "Page \(index)",
                       at: historyNow.addingTimeInterval(Double(index * 60)))
    }
    #expect(history.visits.count == BrowsingHistory.maximumVisits)
    #expect(!history.visits.contains { $0.url == "https://example.com/0" })
    #expect(!history.suggestions(for: "example.com/0", limit: 20_000).contains { $0.url == "https://example.com/0" })
    let url = history.visits[0].url
    history.recordChoice(url: url, query: "page")
    history.remove(url: url)
    #expect(!history.suggestions(for: "page", limit: 20_000).contains { $0.url == url })
    history.clear()
    #expect(history.visits.isEmpty)
    #expect(history.suggestions(for: "page").isEmpty)
    #expect(history.isValid)
}

// @lat: [[lat.md/tests/history-tests#Domain address suggestions]]
@Test func domainAddressSuggestions() {
    var history = BrowsingHistory()
    history.record(url: "https://news.ycombinator.com/from?site=math216.wordpress.com",
                   title: "Submissions from math216.wordpress.com | Hacker News")
    history.record(url: "https://example.org/?site=chess.com", title: "Review of chess.com")
    #expect(history.suggestions(for: "chess.com").isEmpty)
    let page = "https://www.chess.com/play"
    history.record(url: page, title: "Play")
    for query in ["CHESS.COM", "chess.co", "www.chess.com", "https://www.chess.com"] {
        #expect(history.suggestions(for: query).map(\.url) == [page])
    }
    #expect(history.suggestions(for: "http://www.chess.com").isEmpty)
    #expect(history.suggestions(for: "review chess.com").first?.title == "Review of chess.com")
}

// @lat: [[lat.md/tests/history-tests#Home page suggestion ranking]]
@Test func homePageSuggestionRanking() {
    var history = BrowsingHistory()
    let home = "https://github.com/"
    let issue = "https://github.com/postmanlabs/postman-app-support/issues/14370"
    history.record(url: issue, title: "Issue", at: historyNow.addingTimeInterval(-86400))
    history.recordChoice(url: issue, query: "github.com", at: historyNow)
    for index in 0..<35 {
        history.record(url: home, title: "GitHub", at: historyNow.addingTimeInterval(Double(-index * 60)))
    }
    for query in ["github", "github.com", "https://github", "github.com/"] {
        let results = history.suggestions(for: query, now: historyNow)
        #expect(results.first?.url == home)
        #expect(results.first?.visitCount == 35)
        #expect(results.contains { $0.url == issue })
    }
    #expect(history.suggestions(for: "github.com/postman", now: historyNow).first?.url == issue)
    #expect(history.suggestions(for: "issue", now: historyNow).first?.url == issue)

    // Even many selections are a bounded boost, not a permanent veto on visits.
    let frequent = "https://github.com/frequent"
    for index in 0..<20 {
        history.recordChoice(url: issue, query: "repository", at: historyNow)
        history.record(url: frequent, title: "Repository", at: historyNow.addingTimeInterval(Double(-index * 60)))
    }
    history.updateTitle("Repository issue", for: issue)
    #expect(history.suggestions(for: "repository", now: historyNow).first?.url == frequent)

    let timesHome = "https://www.nytimes.com/"
    let timesArticle = "https://www.nytimes.com/international/story"
    history.record(url: timesHome, title: "The New York Times", at: historyNow)
    for index in 0..<20 {
        history.record(url: timesArticle, title: "Article", at: historyNow.addingTimeInterval(Double(-index * 60)))
    }
    for query in ["nytim", "nytimes.com", "nytimes.com/", "www.nytim", "https://www.nytim"] {
        #expect(history.suggestions(for: query, now: historyNow).first?.url == timesHome)
    }
    let pathMatch = history.suggestions(for: "nytimes.com/int", now: historyNow).first
    #expect(pathMatch?.url == timesArticle)
    #expect(pathMatch?.completion(for: "nytimes.com/int") == "nytimes.com/international/story")
}

// @lat: [[lat.md/tests/history-tests#Matched address characters]]
@Test func matchedAddressCharacters() {
    func characters(_ query: String, _ text: String) -> String {
        FuzzyMatch.ranges(query, in: text).map { (text as NSString).substring(with: $0) }.joined()
    }
    #expect(characters("dcs/api", "docs.example.net/reference/api") == "dcs/api")
    #expect(characters("npe", "NullPointerException") == "NPE")
    #expect(characters("cfe", "🙂 Cafe\u{301}") == "Cfe\u{301}")
    #expect(FuzzyMatch.ranges("cfe", in: "🙂 Cafe\u{301}") == [NSRange(location: 3, length: 1), NSRange(location: 5, length: 1), NSRange(location: 6, length: 2)])
    #expect(characters("strasse", "Straße") == "Straße")
    #expect(characters("abc", "abxxc axbc") == "abc")
    #expect(FuzzyMatch.ranges("abc", in: "abxxc axbc") == [NSRange(location: 0, length: 1), NSRange(location: 1, length: 1), NSRange(location: 4, length: 1)])
    #expect(characters("docs api", "Docs / API") == "DocsAPI")
    #expect(FuzzyMatch.ranges("zzz", in: "Docs / API").isEmpty)
    #expect(FuzzyMatch.ranges("", in: "Docs / API").isEmpty)
    var history = BrowsingHistory()
    history.record(url: "https://docs.example.net/reference/api", title: "Reference")
    #expect(history.suggestions(for: "dcs/api").first?.url == "https://docs.example.net/reference/api")
}

// @lat: [[lat.md/tests/history-tests#IPv4 address suggestions]]
@Test func ipv4AddressSuggestions() throws {
    var history = BrowsingHistory()
    let router = "https://10.23.4.1/"
    let admin = "http://10.23.4.1:8080/admin"
    let neighbor = "https://10.230.1.2/"
    for url in [router, admin, neighbor, "https://110.23.4.1/", "https://10.2.3.1/",
                "https://arxiv.org/abs/2610.21375", "https://example.com/10.23",
                "https://10.23.example.com/", "https://example.com/"] {
        history.record(url: url, title: "10.23 router", at: historyNow)
    }
    for query in ["10.23", " 10.23 "] {
        let results = history.suggestions(for: query, limit: 20, now: historyNow)
        #expect(Set(results.map(\.url)) == Set([router, admin, neighbor]))
        #expect(results.allSatisfy { !$0.isFuzzyMatch })
    }
    #expect(history.suggestions(for: "10.23.", now: historyNow).map(\.url).contains(router))
    #expect(!history.suggestions(for: "10.23.", now: historyNow).map(\.url).contains(neighbor))
    #expect(history.suggestions(for: "10.23.4.1", now: historyNow).first?.url == router)
    #expect(history.suggestions(for: "10.23.4.1:8080/ad", now: historyNow).map(\.url) == [admin])
    #expect(history.suggestions(for: "https://10.23.", now: historyNow).map(\.url) == [router])
    #expect(history.suggestions(for: "http://10.23.", now: historyNow).map(\.url) == [admin])
    #expect(history.suggestions(for: "192.168.", now: historyNow).isEmpty)
    #expect(history.suggestions(for: "10.23.4.1/missing", now: historyNow).isEmpty)
    let suggestion = try #require(history.suggestions(for: "10.23.", now: historyNow).first)
    #expect(suggestion.completion(for: "10.23.") == "10.23.4.1/")
    // Ordinary numeric/text searches and the history page retain their matching.
    #expect(!history.suggestions(for: "2610.21375", now: historyNow).isEmpty)
    #expect(!history.suggestions(for: "10.23 router", now: historyNow).isEmpty)
    #expect(history.matching("10.23").contains { $0.url == "https://example.com/" })
}

// @lat: [[lat.md/tests/history-tests#Address matching corpus]]
@Test func addressMatchingCorpus() throws {
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/address-matching.txt")
    let lines = try String(contentsOf: fixture, encoding: .utf8).components(separatedBy: .newlines)
    let header = try #require(lines.firstIndex { $0.hasPrefix("QUERY ") })
    let cases = lines.dropFirst(header + 1).split(whereSeparator: { $0.isEmpty })
    #expect(!cases.isEmpty)
    for rows in cases {
        var history = BrowsingHistory()
        var expected: [String] = []
        var query: String?
        for row in rows {
            let fields = row.components(separatedBy: "  ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            try #require(fields.count == 5, "Malformed corpus row: \(row)")
            let visits = try #require(Int(fields[2]))
            let url = fields[3].contains("://") ? fields[3] : "https://" + fields[3]
            #expect(query == nil || query == fields[0])
            query = fields[0]
            for visit in 0..<visits {
                history.record(url: url, title: fields[4] == "." ? url : fields[4],
                               at: historyNow.addingTimeInterval(Double(-60 * visit)))
            }
            if fields[1] != "-" {
                #expect(Int(fields[1]) == expected.count + 1)
                expected.append(url)
            }
        }
        let input = try #require(query)
        let actual = history.suggestions(for: input, limit: rows.count, now: historyNow).map(\.url)
        #expect(actual == expected, "Query: \(input)")
    }
}
