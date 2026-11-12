import Foundation
import Testing
@testable import BrowseCore

private let historyNow = Date(timeIntervalSince1970: 1_800_000_000)

// @lat: [[lat.md/tests/history-tests#History recording]]
@Test func historyRecording() throws {
    var history = BrowsingHistory()
    let internalPage = history.record(url: "browse://history", title: "History")
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
    #expect(times.completion(for: "NYtim") == "NYtimes.com/")
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
    let url = history.visits[0].url
    history.recordChoice(url: url, query: "page")
    history.remove(url: url)
    #expect(!history.suggestions(for: "page", limit: 20_000).contains { $0.url == url })
    history.clear()
    #expect(history.visits.isEmpty)
    #expect(history.suggestions(for: "page").isEmpty)
    #expect(history.isValid)
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
