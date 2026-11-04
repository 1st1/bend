import Foundation
import Testing
@testable import BrowseCore

private let historyNow = Date(timeIntervalSince1970: 1_800_000_000)

// @lat: [[tests#History recording]]
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

// @lat: [[tests#History matching and completion]]
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
}

// @lat: [[tests#History ranking and learned choices]]
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

// @lat: [[tests#History removal and bounds]]
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
