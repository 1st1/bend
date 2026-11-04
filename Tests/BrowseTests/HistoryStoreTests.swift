import AppKit
import Foundation
import Testing
import WebKit
@testable import Browse

// @lat: [[tests#History persistence and clearing]]
@Test @MainActor func historyPersistence() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseHistory-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("session.json")
    let store = BrowserStore(sessionFile: file)
    store.recordVisit(url: "https://example.com/page", title: "Example")
    store.recordHistoryChoice(url: "https://example.com/page", query: "example")
    store.saveHistory()
    let restored = BrowserStore(sessionFile: file)
    #expect(restored.history == store.history)
    #expect(restored.historyError == nil)
    restored.removeHistory(url: "https://example.com/page")
    #expect(BrowserStore(sessionFile: file).history.visits.isEmpty)
    restored.recordVisit(url: "https://example.com/another", title: "Another")
    restored.clearHistory()
    restored.saveHistory()
    #expect(BrowserStore(sessionFile: file).history.visits.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: file.path))
}

// @lat: [[tests#Unreadable history preservation]]
@Test @MainActor func unreadableHistory() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseHistory-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("history.json")
    let original = Data("broken history".utf8)
    try original.write(to: file)
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"))
    #expect(store.historyError != nil)
    store.recordVisit(url: "https://example.com/", title: "Example")
    store.saveHistory()
    #expect(try Data(contentsOf: file) == original)
    store.clearHistory()
    #expect(store.historyError == nil)
    #expect(BrowserStore(sessionFile: root.appendingPathComponent("session.json")).history.visits.isEmpty)
}

@MainActor
private final class HistoryWebView: FocusWebView {
    var currentURL: URL?
    var currentTitle = "Example"
    var testIsLoading = false
    override var url: URL? { currentURL }
    override var title: String? { currentTitle }
    override var isLoading: Bool { testIsLoading }
}

// @lat: [[tests#Completed navigation history]]
@Test @MainActor func completedNavigationHistory() {
    _ = NSApplication.shared
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    let web = HistoryWebView(frame: .zero, configuration: config)
    let controller = PageController(address: "browse://start", webView: web)
    var visits: [String] = []
    var titles: [String] = []
    controller.onVisit = { url, _ in visits.append(url) }
    controller.onHistoryTitleChanged = { _, title in titles.append(title) }
    controller.isStartPage = false
    controller.webView(web, didStartProvisionalNavigation: nil)
    web.currentURL = URL(string: "https://example.com/final")
    controller.refresh()
    #expect(visits.isEmpty)
    controller.webView(web, didFinish: nil)
    #expect(visits == ["https://example.com/final"])
    controller.refresh()
    #expect(visits.count == 1)
    web.currentTitle = "Updated title"
    controller.refresh()
    #expect(titles == ["Updated title"])
    #expect(visits.count == 1)
    web.currentURL = URL(string: "https://example.com/final#section")
    controller.refresh()
    #expect(visits.count == 2)
    controller.webView(web, didStartProvisionalNavigation: nil)
    web.currentURL = URL(string: "https://example.com/failed")
    controller.webView(web, didFailProvisionalNavigation: nil, withError: URLError(.cannotConnectToHost))
    #expect(visits.count == 2)
    controller.navigate("browse://history")
    controller.webView(web, didFinish: nil)
    #expect(visits.count == 2)
}
