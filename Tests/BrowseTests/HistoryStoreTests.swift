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
    let secondary = BrowserStore(sessionFile: root.appendingPathComponent("Windows/secondary.json"), sharedStore: store)
    #expect(secondary.history == store.history)
    secondary.recordVisit(url: "https://example.com/from-second-window", title: "Second window")
    secondary.saveHistory()
    #expect(store.history == secondary.history)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Windows/History.db").path))
    secondary.removeHistory(url: "https://example.com/from-second-window")
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
@Test(arguments: ["history.json", "History.db"]) @MainActor func unreadableHistory(fileName: String) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseHistory-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent(fileName)
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

// @lat: [[tests#Remove address suggestion]]
@Test @MainActor func removeAddressSuggestion() throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseRemoveSuggestion-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("session.json")
    let store = BrowserStore(sessionFile: file, persistentExtensions: false)
    let url = "https://example.com/unwanted"
    store.recordVisit(url: url, title: "Unwanted")
    store.recordHistoryChoice(url: url, query: "example")
    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 900, height: 700),
        styleMask: [.titled], backing: .buffered, defer: false)
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    let panel = AddressPanelController(store: store, parentWindow: window)
    panel.show(for: store.selectedTab.focusedPane)
    defer { panel.dismiss(restoreFocus: false) }
    let table = NSTableView()
    #expect(panel.numberOfRows(in: table) == 1)
    let cell = try #require(panel.tableView(table, viewFor: nil, row: 0))
    let button = try #require(cell.subviews.compactMap { $0 as? NSButton }.first)
    #expect(button.toolTip == "Remove from history")
    #expect(window.childWindows?.count == 1)
    button.performClick(nil)
    #expect(window.childWindows?.count == 1)
    #expect(panel.numberOfRows(in: table) == 0)
    #expect(store.history.visits.isEmpty)
    #expect(store.history.suggestions(for: "example").isEmpty)
    #expect(BrowserStore(sessionFile: file, persistentExtensions: false).history == store.history)
    #expect(store.selectedTab.pages[0].address == "browse://start")
}
