import AppKit
import BrowseCore
import Testing
import WebKit
@testable import Browse

// @lat: [[lat.md/tests/pane-materials-tests#Header glass after window transfer]]
@Test @MainActor func headerGlassAfterWindowTransfer() async throws {
    guard #available(macOS 26.0, *) else { return }
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendHeaderGlass-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let owner = BrowserWindows(root: root, persistentExtensions: false)
    owner.restore(show: false)
    let source = try #require(owner.active)
    defer { owner.prepareToQuit(); for context in owner.windows { context.window.close() } }
    let tabs = [BrowserTab(), BrowserTab()]
    source.store.session.workspaces = [Workspace(name: "Test", tabs: tabs)]
    source.store.session.selectedTab = tabs[0].id
    source.window.setFrame(NSRect(x: 50, y: 50, width: 1000, height: 700), display: true)
    source.window.orderFront(nil)
    let pages = tabs.map { source.store.controller(for: $0.pages[0]) }
    for page in pages {
        page.isStartPage = false
        page.webView.loadHTMLString("""
            <body style='margin:0;background:white;height:3000px'>
            <input value='unsaved'><script>window.transferToken='alive'</script></body>
            """, baseURL: nil)
        for _ in 0..<80 {
            if (try? await page.webView.evaluateJavaScript("window.transferToken")) as? String == "alive" { break }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
    func settle() async throws {
        for _ in 0..<12 {
            for context in owner.windows { context.window.contentView?.layoutSubtreeIfNeeded() }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
    func verify(_ page: PageController) throws {
        let web = page.webView
        let surface = try #require(web.superview as? WebSurfaceHost)
        #expect(web.obscuredContentInsets.top > 0)
        #expect(web.frame == surface.bounds)
        // Observe the real native effect, rather than merely checking that
        // our optional bridge was called. Its internal blur can turn opaque
        // after reparenting; the containing view must remain suppressed.
        let pocket = try #require(web.subviews.first { String(describing: type(of: $0)) == "NSScrollPocket" })
        #expect(pocket.isHidden)
        let glass = try #require(surface.subviews.first { String(describing: type(of: $0)) == "PaneHeaderGlass" })
        #expect(!glass.isHidden)
        #expect(glass.frame.height == web.obscuredContentInsets.top)
    }
    try await settle()
    try verify(pages[0])
    source.store.select(tabs[1].id)
    try await settle()
    try verify(pages[1])
    for _ in 0..<2 {
        let detached = try #require(owner.detach(tab: tabs[1].id, pane: nil, from: source.store,
                                               at: NSPoint(x: 800, y: 500)))
        try await settle()
        try verify(pages[1])
        #expect(detached.store.transfer(tab: tabs[1].id, to: source.store,
                                       at: .insert(relativeTo: tabs[0].id, after: true)))
        try await settle()
        try verify(pages[1])
        #expect(source.store.existingController(for: tabs[1].pages[0].id) === pages[1])
        #expect(try await pages[1].webView.evaluateJavaScript("window.transferToken") as? String == "alive")
        #expect(try await pages[1].webView.evaluateJavaScript("document.querySelector('input').value") as? String == "unsaved")
        for offset in [400, 0] {
            _ = try await pages[1].webView.evaluateJavaScript("window.scrollTo(0, \(offset))")
            try await settle()
            try verify(pages[1])
            #expect(try await pages[1].webView.evaluateJavaScript("window.scrollY") as? Int == offset)
        }
        source.store.select(tabs[0].id)
        try await settle()
        try verify(pages[0])
        source.store.select(tabs[1].id)
        try await settle()
        try verify(pages[1])
    }
}
