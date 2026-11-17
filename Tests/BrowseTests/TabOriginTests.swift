import AppKit
import BrowseCore
import Foundation
import Testing
import WebKit
@testable import Browse

// @lat: [[lat.md/tests/link-navigation-tests#Return to origin tab]]
@Test @MainActor func closingLinkTabReturnsToOrigin() throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    defer { store.stopWindow(); try? FileManager.default.removeItem(at: root) }
    let origin = store.selectedTab
    let controller = store.controller(for: origin.pages[0])
    store.newTab(address: "bend://history")
    let unrelated = store.selectedTab.id
    store.select(origin.id)
    // Context-menu iframe links have no WebKit opener, but retain their origin tab.
    controller.onOpenLink?("bend://history", false, .newTab)
    let child = try #require(store.session.workspaces.flatMap(\.tabs).first { $0.originTabID == origin.id })
    #expect(store.selectedTab.id == origin.id)
    store.select(child.id)
    store.controller(for: child.pages[0]).onNewTab?("bend://history")
    #expect(store.selectedTab.id == child.id)
    let grandchild = try #require(store.session.workspaces.flatMap(\.tabs).first { $0.originTabID == child.id }).id
    store.select(grandchild)
    store.closeTab(grandchild)
    #expect(store.selectedTab.id == child.id)
    // Persist origin metadata along with the session.
    let restored = try JSONDecoder().decode(BrowserSession.self, from: JSONEncoder().encode(store.session))
    #expect(restored.workspaces.flatMap(\.tabs).first { $0.id == child.id }?.originTabID == origin.id)
    store.closeTab(child.id)
    #expect(store.selectedTab.id == origin.id)
    controller.onNewLink?("bend://history", false, false)
    let second = try #require(store.session.workspaces.flatMap(\.tabs).first { $0.originTabID == origin.id }).id
    #expect(store.selectedTab.id == second)
    store.select(unrelated)
    store.closeTab(second)
    #expect(store.selectedTab.id == unrelated)
    store.select(origin.id)
    controller.onNewTab?("bend://history")
    #expect(store.selectedTab.id == origin.id)
    let orphan = try #require(store.session.workspaces.flatMap(\.tabs).first { $0.originTabID == origin.id }).id
    store.select(orphan)
    store.closeTab(origin.id)
    #expect(store.selectedTab.id == orphan)
    store.closeTab(orphan)
    #expect(store.selectedTab.id == unrelated)
    #expect(store.session.isValid)
}

// @lat: [[lat.md/tests/link-navigation-tests#Back closes link-created tabs]]
@Test @MainActor func backClosesLinkTabs() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    let other = BrowserStore(sessionFile: root.appendingPathComponent("other.json"), persistentExtensions: false, sharedStore: store)
    defer { other.stopWindow(); store.stopWindow(); try? FileManager.default.removeItem(at: root) }
    #expect(store.closeLinkTabOnBack)
    let origin = store.selectedTab
    let source = store.controller(for: origin.pages[0])
    #expect(!store.canGoBack(from: origin.focusedPane))
    store.goBack(from: origin.focusedPane)
    #expect(store.selectedTab.id == origin.id)

    source.onNewLink?("bend://start", false, false)
    let child = store.selectedTab
    let page = store.controller(for: child.pages[0])
    #expect(store.canGoBack(from: child.focusedPane))
    other.closeLinkTabOnBack = false
    #expect(!store.closeLinkTabOnBack)
    #expect(!store.canGoBack(from: child.focusedPane))
    store.goBack(from: child.focusedPane)
    #expect(store.selectedTab.id == child.id)
    store.save()
    let restored = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    #expect(!restored.closeLinkTabOnBack)
    restored.stopWindow()
    other.closeLinkTabOnBack = true

    store.setTabPinned(child.id, pinned: true)
    #expect(!store.canGoBack(from: child.focusedPane))
    store.goBack(from: child.focusedPane)
    #expect(store.selectedTab.id == child.id)
    store.setTabPinned(child.id, pinned: false)

    // Real WebKit history must be traversed before Back can close the tab.
    let first = root.appendingPathComponent("first.html")
    let second = root.appendingPathComponent("second.html")
    try "<title>First page</title>".write(to: first, atomically: true, encoding: .utf8)
    try "<title>Second page</title>".write(to: second, atomically: true, encoding: .utf8)
    page.navigate(first.absoluteString)
    func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(condition(), "url=\(String(describing: page.webView.url)) title=\(String(describing: page.webView.title)) error=\(String(describing: page.error)) back=\(page.webView.backForwardList.backList.map { $0.url.absoluteString })")
    }
    try await wait { page.webView.title == "First page" && !page.webView.isLoading }
    #expect(page.backItemClosesPage)
    #expect(page.address == first.absoluteString)
    #expect(store.selectedTab.pages[0].address == first.absoluteString)
    // Disabled and pinned tabs reject real WebKit history navigation to the marker.
    other.closeLinkTabOnBack = false
    page.webView.goBack()
    try await Task.sleep(for: .milliseconds(150))
    #expect(store.selectedTab.id == child.id)
    #expect(page.webView.url == first)
    #expect(!store.canGoBack(from: child.focusedPane))
    let markerItem = try #require(page.webView.backForwardList.backItem)
    var earlyDecision: Bool?
    page.webView(page.webView, shouldGoTo: markerItem, willUseInstantBack: true) { earlyDecision = $0 }
    #expect(earlyDecision == false)
    let currentItem = try #require(page.webView.backForwardList.currentItem)
    page.webView(page.webView, shouldGoTo: currentItem, willUseInstantBack: false) { earlyDecision = $0 }
    #expect(earlyDecision == true)
    other.closeLinkTabOnBack = true
    store.setTabPinned(child.id, pinned: true)
    page.webView.goBack()
    try await Task.sleep(for: .milliseconds(150))
    #expect(store.selectedTab.id == child.id)
    #expect(page.webView.url == first)
    store.setTabPinned(child.id, pinned: false)
    // A normal request to the exact marker must not close the tab.
    let marker = try #require(page.webView.backForwardList.backItem?.url)
    page.webView.load(URLRequest(url: marker))
    try await Task.sleep(for: .milliseconds(150))
    #expect(store.selectedTab.id == child.id)
    #expect(page.webView.url == first)
    page.navigate(second.absoluteString)
    try await wait { page.webView.title == "Second page" && page.webView.canGoBack && !page.webView.isLoading }
    store.goBack(from: child.focusedPane)
    #expect(store.selectedTab.id == child.id)
    try await wait { page.webView.title == "First page" && page.backItemClosesPage && !page.webView.isLoading }
    #expect(page.webView.canGoBack)
    page.webView.goBack()
    try await wait { store.selectedTab.id == origin.id }
    #expect(store.selectedTab.id == origin.id)
    #expect(store.canReopenClosed)

    store.newTab(address: "bend://history")
    let manual = store.selectedTab
    _ = store.controller(for: manual.pages[0])
    store.goBack(from: manual.focusedPane)
    #expect(store.selectedTab.id == manual.id)
    #expect(!store.canGoBack(from: manual.focusedPane))
    store.select(origin.id)
    source.onNewLink?("bend://history", false, true)
    let split = store.selectedTab
    store.split(.horizontal)
    let manualSplit = store.selectedTab.focusedPane
    #expect(!store.canGoBack(from: manualSplit))
    store.goBack(from: manualSplit)
    #expect(store.selectedTab.pages.count == 2)
    #expect(store.canGoBack(from: split.focusedPane))
    _ = store.controller(for: split.pages[0])
    store.goBack(from: split.focusedPane)
    #expect(store.selectedTab.id == split.id)
    #expect(store.selectedTab.pages.map(\.id) == [manualSplit])
    #expect(store.session.isValid)
}

// @lat: [[lat.md/tests/link-navigation-tests#Back closes link-created panes]]
@Test @MainActor func backClosesLinkPanes() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    let other = BrowserStore(sessionFile: root.appendingPathComponent("other.json"), persistentExtensions: false, sharedStore: store)
    defer { other.stopWindow(); store.stopWindow(); try? FileManager.default.removeItem(at: root) }
    #expect(store.closeLinkPaneOnBack)
    store.newTab()
    let origin = store.selectedTab.focusedPane
    let tabID = store.selectedTab.id
    let first = root.appendingPathComponent("first.html")
    let second = root.appendingPathComponent("second.html")
    try "<title>First pane page</title>".write(to: first, atomically: true, encoding: .utf8)
    try "<title>Second pane page</title>".write(to: second, atomically: true, encoding: .utf8)
    store.openPane(address: first.absoluteString, toRightOf: origin, fromMainFrame: false)
    let child = store.selectedTab.pages.last!
    let page = store.controller(for: child)
    func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(condition())
    }
    try await wait { page.webView.title == "First pane page" && !page.webView.isLoading }
    #expect(child.originPageID == origin)
    #expect(page.backItemClosesPage)
    other.closeLinkPaneOnBack = false
    #expect(!store.canGoBack(from: child.id))
    page.webView.goBack()
    try await Task.sleep(for: .milliseconds(150))
    #expect(store.selectedTab.pages.count == 2)
    #expect(page.webView.url == first)
    store.save()
    let restored = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    #expect(!restored.closeLinkPaneOnBack)
    #expect(restored.selectedTab.pages.first { $0.id == child.id }?.originPageID == origin)
    restored.stopWindow()
    other.closeLinkPaneOnBack = true
    store.closeLinkTabOnBack = false
    page.navigate(second.absoluteString)
    try await wait { page.webView.title == "Second pane page" && !page.webView.isLoading }
    store.goBack(from: child.id)
    try await wait { page.webView.title == "First pane page" && !page.webView.isLoading }
    #expect(store.selectedTab.pages.count == 2)
    page.webView.goBack()
    try await wait { store.selectedTab.pages.count == 1 }
    #expect(store.selectedTab.id == tabID)
    #expect(store.selectedTab.focusedPane == origin)
    store.reopenClosed()
    #expect(store.selectedTab.pages.count == 2)
    #expect(store.selectedTab.pages.first { $0.id == child.id }?.address == first.absoluteString)
    let reopened = store.controller(for: store.selectedTab.pages.first { $0.id == child.id }!)
    try await wait { reopened.webView.title == "First pane page" && !reopened.webView.isLoading }
    store.goBack(from: child.id)
    #expect(store.selectedTab.pages.count == 1)
    store.split(.horizontal)
    let manual = store.selectedTab.pages.first { $0.id == store.selectedTab.focusedPane }!
    _ = store.controller(for: manual)
    #expect(!store.canGoBack(from: manual.id))
    store.goBack(from: manual.id)
    #expect(store.selectedTab.pages.count == 2)
    #expect(store.session.isValid)
}

// @lat: [[lat.md/tests/link-navigation-tests#Back closes original pane of a split link tab]]
@Test @MainActor func backClosesOriginalLinkTabPane() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    defer { store.stopWindow(); try? FileManager.default.removeItem(at: root) }
    let source = store.selectedTab.focusedPane
    let file = root.appendingPathComponent("linked.html")
    try "<title>Linked page</title>".write(to: file, atomically: true, encoding: .utf8)
    store.newTab(address: file.absoluteString, originPageID: source)
    let tabID = store.selectedTab.id
    let original = store.selectedTab.pages[0]
    let page = store.controller(for: original)
    func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(condition())
    }
    try await wait { page.webView.title == "Linked page" && !page.webView.isLoading }
    store.openPane(address: "bend://start", toRightOf: original.id)
    let remaining = store.selectedTab.focusedPane
    store.closeLinkTabOnBack = false
    store.closeLinkPaneOnBack = false
    #expect(!store.canGoBack(from: original.id))
    page.webView.goBack()
    try await Task.sleep(for: .milliseconds(150))
    #expect(store.selectedTab.pages.count == 2)
    store.closeLinkPaneOnBack = true
    #expect(store.canGoBack(from: original.id))
    page.webView.goBack()
    try await wait { store.selectedTab.pages.count == 1 }
    #expect(store.selectedTab.id == tabID)
    #expect(store.selectedTab.pages[0].id == remaining)
    #expect(store.selectedTab.focusedPane == remaining)
    store.reopenClosed()
    #expect(store.selectedTab.pages.first { $0.id == original.id }?.originPageID == source)
    #expect(store.selectedTab.pages.first { $0.id == original.id }?.address == file.absoluteString)
}

// @lat: [[lat.md/tests/link-navigation-tests#Disabled marker swipe suppression]]
@Test @MainActor func disabledMarkerSwipeSuppression() throws {
    _ = NSApplication.shared
    let web = WKWebView()
    var blocked = true
    let guarder = HistorySwipeGuard(webView: web, blocked: { blocked })
    func event(_ delta: Int32, phase: Int64, momentum: Int64 = 0) throws -> NSEvent {
        let cg = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: delta, wheel3: 0))
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        return try #require(NSEvent(cgEvent: cg))
    }
    // A zero-delta begin must reach WebKit so forward swipes can initialize.
    guarder.observe(try event(0, phase: 1))
    #expect(web.allowsBackForwardNavigationGestures)
    guarder.observe(try event(1, phase: 2))
    #expect(!web.allowsBackForwardNavigationGestures)
    guarder.observe(try event(-1, phase: 2))
    guarder.observe(try event(0, phase: 4))
    guarder.observe(try event(100, phase: 0, momentum: 2))
    #expect(!web.allowsBackForwardNavigationGestures)
    // Forward remains native even at the sentinel boundary.
    guarder.observe(try event(0, phase: 1))
    guarder.observe(try event(-1, phase: 2))
    #expect(web.allowsBackForwardNavigationGestures)
    guarder.observe(try event(1, phase: 1))
    #expect(!web.allowsBackForwardNavigationGestures)
    blocked = false
    guarder.historyDidChange()
    #expect(web.allowsBackForwardNavigationGestures)
    guarder.observe(try event(1, phase: 1))
    #expect(web.allowsBackForwardNavigationGestures)
}
