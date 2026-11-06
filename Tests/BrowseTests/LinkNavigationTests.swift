import AppKit
import BrowseCore
import Testing
import WebKit
@testable import Browse

@MainActor
private final class LinkAction: WKNavigationAction {
    var modifiers: NSEvent.ModifierFlags = .command
    // WKNavigationAction uses a button mask: left = 1, right = 2, middle = 4.
    var button = 1
    var kind: WKNavigationType = .linkActivated
    var destination = URL(string: "https://example.com/target?q=one#section")!
    override var modifierFlags: NSEvent.ModifierFlags { modifiers }
    override var buttonNumber: Int { button }
    override var navigationType: WKNavigationType { kind }
    override var request: URLRequest { URLRequest(url: destination) }
    override var targetFrame: WKFrameInfo? { nil }
}

// @lat: [[tests#Command-click navigation]]
@Test @MainActor func commandClickNavigation() {
    _ = NSApplication.shared
    let controller = PageController(address: "browse://start")
    var panes: [String] = []
    controller.onNewPane = { panes.append($0) }
    let action = LinkAction()
    var policies: [WKNavigationActionPolicy] = []
    controller.webView(controller.webView, decidePolicyFor: action) { policies.append($0) }
    #expect(policies == [.cancel])
    #expect(panes == [action.destination.absoluteString])
    #expect(controller.address == "browse://start")

    action.modifiers = []
    controller.webView(controller.webView, decidePolicyFor: action) { policies.append($0) }
    #expect(policies.last == .allow)
    action.modifiers = .command
    for button in [0, 2, 4] {
        action.button = button
        controller.webView(controller.webView, decidePolicyFor: action) { policies.append($0) }
        #expect(policies.last == .allow)
    }
    action.button = 1
    action.kind = .other
    controller.webView(controller.webView, decidePolicyFor: action) { policies.append($0) }
    #expect(policies.last == .allow)
    action.kind = .linkActivated
    action.destination = URL(string: "custom://target")!
    controller.webView(controller.webView, decidePolicyFor: action) { policies.append($0) }
    #expect(policies.last == .cancel)
    #expect(panes.count == 1)
}

// @lat: [[tests#Command-click new-window links]]
@Test @MainActor func commandClickNewWindowLink() {
    _ = NSApplication.shared
    let controller = PageController(address: "browse://start")
    var panes: [String] = []
    var tabs: [String] = []
    controller.onNewPane = { panes.append($0) }
    controller.onNewTab = { tabs.append($0) }
    let action = LinkAction()
    let result = controller.webView(controller.webView, createWebViewWith: WKWebViewConfiguration(),
                                    for: action, windowFeatures: WKWindowFeatures())
    #expect(result == nil)
    #expect(panes == [action.destination.absoluteString])
    #expect(tabs.isEmpty)
    action.modifiers = []
    _ = controller.webView(controller.webView, createWebViewWith: WKWebViewConfiguration(),
                           for: action, windowFeatures: WKWindowFeatures())
    #expect(panes.count == 1)
    #expect(tabs == [action.destination.absoluteString])
}

// @lat: [[tests#Configurable link destination]]
@Test @MainActor func configurableLinkDestination() throws {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BrowsePreferences-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = BrowserStore(sessionFile: directory.appendingPathComponent("session.json"), persistentExtensions: false)
    let originalTab = store.selectedTab
    let source = try #require(originalTab.pages.first)
    let controller = store.controller(for: source)
    let initialCount = originalTab.pages.count

    controller.onNewLink?("https://example.com/adjacent", true, true)
    #expect(store.selectedTab.id == originalTab.id)
    #expect(store.selectedTab.pages.count == initialCount + 1)
    #expect(store.linkOpeners[store.selectedTab.focusedPane] == source.id)
    #expect(store.selectedTab.layout.paneIDs.firstIndex(of: store.selectedTab.focusedPane)
        == store.selectedTab.layout.paneIDs.firstIndex(of: source.id).map { $0 + 1 })

    // The same existing controller must use the new preference immediately.
    store.commandClickDestination = .newTab
    controller.onNewLink?("https://example.com/tab", true, true)
    #expect(store.selectedTab.id != originalTab.id)
    #expect(store.selectedTab.pages.count == 1)
    #expect(store.selectedTab.pages[0].address == "https://example.com/tab")
    #expect(store.linkOpeners[store.selectedTab.focusedPane] == source.id)
    #expect(store.session.workspaces[0].tabs.first { $0.id == originalTab.id }?.pages.count == initialCount + 1)

    store.commandClickDestination = .newPane
    controller.onNewLink?("https://example.com/window", false, false)
    #expect(store.selectedTab.id != originalTab.id)
    #expect(store.linkOpeners[store.selectedTab.focusedPane] == nil)
    controller.onNewLink?("https://example.com/adjacent-again", true, false)
    #expect(store.selectedTab.id == originalTab.id)
    #expect(store.selectedTab.pages.count == initialCount + 2)
    #expect(store.linkOpeners[store.selectedTab.focusedPane] == nil)
}

// @lat: [[tests#Dedicated Command-click pane]]
@Test @MainActor func dedicatedCommandClickPane() throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseDedicatedLink-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("session.json")
    let store = BrowserStore(sessionFile: file, persistentExtensions: false)
    store.commandClickDestination = .dedicatedPane
    let original = store.selectedTab
    let source = original.pages[0], other = original.pages[1]
    let sourceController = store.controller(for: source)
    sourceController.onNewLink?("browse://guide", true, true)
    let dedicated = try #require(store.selectedTab.commandClickPaneID)
    #expect(store.selectedTab.pages.count == original.pages.count + 1)
    #expect(store.selectedTab.layout.paneIDs.firstIndex(of: dedicated) == 1)
    let target = store.controller(for: try #require(store.selectedTab.pages.first { $0.id == dedicated }))
    let web = target.webView
    let otherController = store.controller(for: other)
    otherController.onNewLink?("browse://history", true, true)
    #expect(store.selectedTab.pages.count == original.pages.count + 1)
    #expect(store.selectedTab.focusedPane == dedicated && store.selectedTab.commandClickPaneID == dedicated)
    #expect(target.address == "browse://history" && target.webView === web)
    #expect(store.linkOpeners[dedicated] == other.id)
    #expect(sourceController.address == source.address && otherController.address == other.address)
    // Reuse from an iframe clears the preceding main-frame opener. Clicking in
    // the dedicated pane reuses it too, without a self-referential opener.
    sourceController.onNewLink?("browse://guide", true, false)
    #expect(store.linkOpeners[dedicated] == nil)
    target.onNewLink?("browse://history", true, true)
    #expect(store.selectedTab.pages.count == original.pages.count + 1)
    #expect(store.linkOpeners[dedicated] == nil)
    store.newTab(address: "browse://guide")
    let secondTab = store.selectedTab
    store.controller(for: secondTab.pages[0]).onNewLink?("browse://history", true, true)
    #expect(store.selectedTab.pages.count == 2)
    #expect(store.selectedTab.commandClickPaneID != dedicated)
    sourceController.onNewLink?("browse://guide", true, true)
    #expect(store.selectedTab.id == original.id && store.selectedTab.commandClickPaneID == dedicated)
    store.closePage(dedicated)
    #expect(store.selectedTab.commandClickPaneID == nil)
    store.reopenClosed()
    #expect(store.selectedTab.commandClickPaneID == dedicated)
    store.closePage(dedicated)
    sourceController.onNewLink?("browse://history", true, true)
    let replacement = try #require(store.selectedTab.commandClickPaneID)
    #expect(replacement != dedicated)
    #expect(store.selectedTab.pages.count == original.pages.count + 1)
    store.save()
    let restored = BrowserStore(sessionFile: file, persistentExtensions: false)
    #expect(restored.commandClickDestination == .dedicatedPane)
    #expect(restored.selectedTab.commandClickPaneID == replacement)
    restored.controller(for: source).onNewLink?("browse://guide", true, true)
    #expect(restored.selectedTab.commandClickPaneID == replacement)
    #expect(restored.selectedTab.pages.count == original.pages.count + 1)
    // Switching modes is live and must not repurpose an ordinary pane.
    restored.commandClickDestination = .newPane
    restored.controller(for: source).onNewLink?("browse://guide", true, true)
    #expect(restored.selectedTab.pages.count == original.pages.count + 2)
    #expect(restored.selectedTab.commandClickPaneID == replacement)
    restored.commandClickDestination = .dedicatedPane
    restored.controller(for: source).onNewLink?("browse://history", true, true)
    #expect(restored.selectedTab.pages.count == original.pages.count + 2)
    #expect(restored.selectedTab.focusedPane == replacement)

    // The last remaining pane becomes ordinary without losing its live WebView.
    let survivor = try #require(restored.selectedTab.pages.first { $0.id == replacement })
    let survivorController = restored.controller(for: survivor)
    let survivorWeb = survivorController.webView
    let survivorAddress = survivorController.address
    let ordinaryPanes = restored.selectedTab.pages.filter { $0.id != replacement }
    for (index, pane) in ordinaryPanes.enumerated() {
        restored.closePage(pane.id)
        #expect(restored.selectedTab.commandClickPaneID == (index == ordinaryPanes.count - 1 ? nil : replacement))
    }
    #expect(restored.selectedTab.pages.count == 1)
    #expect(restored.selectedTab.focusedPane == replacement)
    #expect(restored.controller(for: survivor).webView === survivorWeb)
    #expect(survivorController.address == survivorAddress)
    restored.save()
    #expect(BrowserStore(sessionFile: file, persistentExtensions: false).selectedTab.commandClickPaneID == nil)
    survivorController.onNewLink?("browse://guide", true, true)
    let newTarget = try #require(restored.selectedTab.commandClickPaneID)
    #expect(newTarget != replacement)
    #expect(restored.selectedTab.pages.count == 2)
    #expect(survivorController.address == survivorAddress && survivorController.webView === survivorWeb)
    #expect(restored.linkOpeners[newTarget] == replacement)
    survivorController.onNewLink?("browse://history", true, true)
    #expect(restored.selectedTab.commandClickPaneID == newTarget && restored.selectedTab.pages.count == 2)

    // Normalize the stale single-pane designation saved by older versions too.
    restored.closePage(newTarget)
    restored.editTab { $0.commandClickPaneID = replacement }
    restored.save()
    let legacyRestored = BrowserStore(sessionFile: file, persistentExtensions: false)
    #expect(legacyRestored.selectedTab.commandClickPaneID == nil)
    #expect(legacyRestored.selectedTab.pages[0].id == replacement)
}

// @lat: [[tests#Command-click preference migration]]
@Test @MainActor func commandClickPreferenceMigration() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseLinkMigration-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("session.json")
    for legacy in [false, true] {
        var session = BrowserSession()
        session.commandClickOpensNewTab = legacy
        try JSONEncoder().encode(session).write(to: file)
        let store = BrowserStore(sessionFile: file, persistentExtensions: false)
        #expect(store.commandClickDestination == (legacy ? .newTab : .newPane))
        store.commandClickDestination = .dedicatedPane
        store.save()
        let restored = BrowserStore(sessionFile: file, persistentExtensions: false)
        #expect(restored.commandClickDestination == .dedicatedPane)
        #expect(restored.session.selectedTab == session.selectedTab)
    }
}
