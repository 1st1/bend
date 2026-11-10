import AppKit
import BrowseCore
import Testing
import WebKit
import WebKitFindSupport
@testable import Browse

@MainActor private final class LinkMenuProbe: BendContextMenuDelegate, WKUIDelegate {
    var controller: PageController?
    var menus: [(NSMenu, URL, Bool)] = []
    override func contextMenu(_ menu: NSMenu, forLinkURL url: URL, fromMainFrame mainFrame: Bool) -> NSMenu {
        let customized = controller?.contextMenu(menu, forLinkURL: url, fromMainFrame: mainFrame) ?? menu
        menus.append((customized, url, mainFrame))
        // Capture the real WebKit menu without starting a modal menu-tracking loop.
        return NSMenu()
    }
}

// @lat: [[tests#Link context menu destinations]]
@Test @MainActor func linkContextMenuDestinations() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendLinkMenu-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let owner = BrowserWindows(root: root, persistentExtensions: false)
    owner.restore(show: false)
    defer { owner.prepareToQuit(); for context in owner.windows { context.window.close() } }
    let origin = try #require(owner.active)
    let store = origin.store
    let original = store.selectedTab
    let source = original.pages[0]
    let controller = store.controller(for: source)
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: configuration)
    let probe = LinkMenuProbe()
    probe.controller = controller
    web.uiDelegate = probe
    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 600, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = web
    window.orderFront(nil)
    defer { web.stopLoading(); window.close() }
    web.loadHTMLString("""
        <style>body { margin:0 } a { display:block; height:60px } iframe { border:0; width:500px; height:120px }</style>
        <a href="../top?q=one%20two#anchor"><span>Top link</span></a>
        <iframe srcdoc="<style>body{margin:0}a{display:block;height:80px}</style><a href='http://127.0.0.1:9/frame?q=three#part'>Frame link</a>"></iframe>
        """, baseURL: URL(string: "http://127.0.0.1:9/folder/page"))
    for _ in 0..<100 {
        if (try? await web.evaluateJavaScript("document.querySelector('iframe')?.contentDocument?.querySelector('a') != null")) as? Bool == true { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    func menu(at point: NSPoint) async throws -> (NSMenu, URL, Bool) {
        let count = probe.menus.count
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: point,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        web.rightMouseDown(with: event)
        for _ in 0..<100 where probe.menus.count == count { try await Task.sleep(for: .milliseconds(20)) }
        try #require(probe.menus.count == count + 1)
        return try #require(probe.menus.last)
    }
    let top = try await menu(at: NSPoint(x: 30, y: 370))
    #expect(top.1.absoluteString == "http://127.0.0.1:9/top?q=one%20two#anchor")
    #expect(top.2)
    #expect(top.0.items.prefix(3).map(\.title) == ["Open Link in New Pane", "Open Link in New Tab", "Open Link in New Window"])
    #expect(top.0.items.contains { $0.tag == 3 }) // WebKit's Copy Link item survives.
    #expect(!top.0.items.contains { $0.tag == 1 }) // No duplicate native window action.
    let frame = try await menu(at: NSPoint(x: 30, y: 300))
    #expect(frame.1.absoluteString == "http://127.0.0.1:9/frame?q=three#part")
    #expect(!frame.2)

    func choose(_ menu: NSMenu, _ index: Int) throws {
        let item = try #require(menu.item(at: index))
        #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
    }
    // Menus retain their own hit target even after another menu is constructed.
    store.commandClickDestination = .dedicatedPane
    store.optionClickDestination = .newWindow
    try choose(top.0, 0)
    #expect(store.selectedTab.id == original.id)
    #expect(store.selectedTab.pages.count == original.pages.count + 1)
    #expect(store.selectedTab.layout.paneIDs[1] == store.selectedTab.focusedPane)
    #expect(store.selectedTab.pages.last?.address == top.1.absoluteString)
    #expect(store.selectedTab.commandClickPaneID == nil)
    #expect(store.linkOpeners[store.selectedTab.focusedPane] == source.id)
    try choose(frame.0, 1)
    #expect(store.selectedTab.id != original.id)
    #expect(store.selectedTab.pages.map(\.address) == [frame.1.absoluteString])
    #expect(store.linkOpeners[store.selectedTab.focusedPane] == nil)
    try choose(top.0, 2)
    #expect(owner.windows.count == 2)
    #expect(owner.windows.last?.store.selectedTab.pages.map(\.address) == [top.1.absoluteString])
    #expect(controller.address == source.address)
}
