import AppKit
import BrowseCore
import Testing
import WebKit
@testable import Browse

// @lat: [[lat.md/tests/developer-tools-tests#Developer tools]]
@Test @MainActor func developerTools() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendInspector-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let windows = BrowserWindows(root: root, persistentExtensions: false)
    windows.restore(show: false)
    let context = try #require(windows.active)
    let store = context.store
    let tab = BrowserTab(pages: [Page(address: "browse://start"), Page(address: "browse://start")])
    store.session.workspaces = [Workspace(name: "Test", tabs: [tab])]
    store.session.selectedTab = tab.id
    let pages = tab.pages.map { store.controller(for: $0) }
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 600))
    for (index, page) in pages.enumerated() {
        let host = WebSurfaceHost(frame: NSRect(x: index * 600, y: 0, width: 600, height: 600))
        container.addSubview(host)
        host.update(webView: page.webView, topContentInset: 44, headerAppearance: .headerDefault)
    }
    context.window.contentView = container
    context.window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    context.window.makeKeyAndOrderFront(nil)
    let delegate = AppDelegate(browserWindows: windows)
    let oldMenu = NSApp.mainMenu
    delegate.installMenus()
    defer {
        NSApp.mainMenu = oldMenu
        windows.prepareToQuit()
        for session in windows.windows { session.window.close() }
    }
    let menu = try #require(NSApp.mainMenu?.item(withTitle: "Develop")?.submenu)
    let console = try #require(menu.item(withTitle: "Show JavaScript Console"))
    let inspectorItem = try #require(menu.item(withTitle: "Show Web Inspector"))
    #expect(!delegate.validateMenuItem(console))
    #expect(!delegate.validateMenuItem(inspectorItem))
    for (index, page) in pages.enumerated() {
        #expect(page.webView.isInspectable)
        page.isStartPage = false
        page.webView.loadHTMLString("""
            <title>Inspector fixture \(index)</title><p>Developer tools</p>
            <script>
            window.emitDiagnostics = () => {
            console.error('BEND_CONSOLE_\(index)');
            setTimeout(() => { throw new Error('BEND_THROW_\(index)'); }, 0);
            Promise.reject(new Error('BEND_REJECTION_\(index)'));
            };
            </script>
            """, baseURL: URL(string: "https://inspector\(index).example"))
    }
    func wait(_ ready: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await ready() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(await ready())
    }
    try await wait { pages.allSatisfy { !$0.webView.isLoading && $0.webView.title?.hasPrefix("Inspector fixture") == true } }
    // Inspect real native frontend content without modifying the inspected page.
    func frontend(_ web: WKWebView) -> WKWebView? {
        let selector = NSSelectorFromString("_inspector")
        guard web.responds(to: selector),
              let inspector = web.perform(selector)?.takeUnretainedValue() as? NSObject else { return nil }
        let frontendSelector = NSSelectorFromString("inspectorWebView")
        guard inspector.responds(to: frontendSelector) else { return nil }
        return inspector.perform(frontendSelector)?.takeUnretainedValue() as? WKWebView
    }
    func contents(_ web: WKWebView) async -> String {
        guard let ui = frontend(web) else { return "" }
        // Offscreen windows do not receive animation frames; flush the native
        // frontend's pending view layout before inspecting rendered messages.
        _ = try? await ui.evaluateJavaScript("WI.consoleContentView?._logViewController.renderPendingMessages(); WI.consoleContentView?.updateLayout(); void 0")
        return (try? await ui.evaluateJavaScript("document.body.innerText")) as? String ?? ""
    }
    #expect(delegate.validateMenuItem(console))
    let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: context.window.windowNumber, context: nil,
        characters: "I", charactersIgnoringModifiers: "i", isARepeat: false, keyCode: 34))
    #expect(try #require(NSApp.mainMenu).performKeyEquivalent(with: key))
    #expect(NSApp.sendAction(try #require(console.action), to: console.target, from: console))
    try await wait { await contents(pages[0].webView).contains("Console opened") }
    // Reproduce errors after attaching, as when reloading a failing website.
    for page in pages { _ = try await page.webView.evaluateJavaScript("emitDiagnostics(); void 0") }
    try await wait { await contents(pages[0].webView).contains("BEND_REJECTION_0") }
    let text = await contents(pages[0].webView)
    #expect(text.contains("BEND_CONSOLE_0"))
    #expect(text.contains("BEND_THROW_0"))
    #expect(!text.contains("BEND_CONSOLE_1"))
    #expect(pages[0].webView.inspector.isVisible)
    #expect(!pages[1].webView.inspector.isVisible)
    let firstFrontend = try #require(frontend(pages[0].webView))
    #expect(firstFrontend.window === context.window)
    let firstHost = try #require(pages[0].webView.superview as? WebSurfaceHost)
    let panel = try #require(firstHost.developerToolsPanel)
    #expect(firstFrontend.isDescendant(of: panel))
    context.window.makeFirstResponder(pages[0].webView)
    #expect(NSApp.sendAction(try #require(console.action), to: console.target, from: console))
    #expect((context.window.firstResponder as? NSView)?.isDescendant(of: panel) == true)
    #expect(pages[0].webView.frame.minY == panel.frame.maxY)
    #expect(pages[1].webView.frame.minY == 0)
    let dockingControls = try await firstFrontend.evaluateJavaScript("""
        ['_closeTabBarButton', '_dockRightTabBarButton', '_dockBottomTabBarButton'].every(key => WI[key] && !WI[key].hidden)
            && ['_dockLeftTabBarButton', '_undockTabBarButton'].every(key => !WI[key] || WI[key].hidden)
        """) as? Bool
    #expect(dockingControls == true)
    #expect(try await pages[0].webView.evaluateJavaScript("!!window.webkit?.messageHandlers?.bendInspector") as? Bool == false)
    let windowFrame = context.window.frame
    func dragDivider(from start: NSPoint, by delta: NSPoint) throws {
        let start = panel.convert(start, to: nil)
        let end = NSPoint(x: start.x + delta.x, y: start.y + delta.y)
        try sendPaneMouse(.leftMouseDown, at: start, to: context.window)
        try sendPaneMouse(.leftMouseDragged, at: end, to: context.window)
        try sendPaneMouse(.leftMouseUp, at: end, to: context.window)
        #expect(context.window.frame == windowFrame)
    }
    let initialHeight = panel.frame.height
    try dragDivider(from: NSPoint(x: panel.bounds.midX, y: panel.bounds.maxY - 2), by: NSPoint(x: 0, y: 40))
    #expect(panel.frame.height == initialHeight + 40)
    firstHost.performFindAction(.showFindInterface)
    #expect(firstHost.isFindBarVisible)
    #expect(pages[0].webView.frame.minY == panel.frame.maxY)
    firstHost.hideFindBar()
    // Element inspection asks WebKit to reveal its frontend before docking.
    _ = try await firstFrontend.evaluateJavaScript("""
        WI.runtimeManager.evaluateInInspectedWindow("inspect(document.querySelector('p'))", {objectGroup:'console', includeCommandLineAPI:true}, () => {}); void 0
        """)
    try await wait { await contents(pages[0].webView).contains("<p>") }
    #expect(firstFrontend.superview === panel)
    // Use the actual WebKit toolbar buttons, preserving the live console.
    _ = try await firstFrontend.evaluateJavaScript("WI._dockRightTabBarButton.element.click(); void 0")
    try await wait { panel.dock == .right }
    #expect(firstFrontend.superview === panel)
    #expect(firstFrontend.frame.maxX <= panel.bounds.maxX)
    #expect(pages[0].webView.frame.maxX == panel.frame.minX)
    #expect(pages[0].webView.frame.minY == 0)
    #expect(panel.frame.maxY <= firstHost.bounds.height - 44)
    #expect(firstFrontend.window === context.window)
    // A later native reveal (also used by element picking and breakpoints)
    // must not take the frontend back, even when the page is too narrow to dock.
    let nativeInspector = try #require(pages[0].webView.perform(NSSelectorFromString("_inspector"))?.takeUnretainedValue() as? NSObject)
    #expect(nativeInspector.responds(to: NSSelectorFromString("show")))
    nativeInspector.perform(NSSelectorFromString("show"))
    try await wait { firstFrontend.superview === panel && firstFrontend.window === context.window }
    #expect(pages[0].webView.frame.maxX == panel.frame.minX)
    let initialWidth = panel.frame.width
    try dragDivider(from: NSPoint(x: 2, y: panel.bounds.midY), by: NSPoint(x: -30, y: 0))
    #expect(panel.frame.width == initialWidth + 30)
    _ = try await firstFrontend.evaluateJavaScript("WI.showConsoleTab(); void 0")
    try await wait { await contents(pages[0].webView).contains("BEND_CONSOLE_0") }
    firstHost.frame.size = NSSize(width: 340, height: 400)
    firstHost.layoutSubtreeIfNeeded()
    #expect(pages[0].webView.frame.width >= 100)
    #expect(pages[0].webView.frame.maxX == panel.frame.minX)
    #expect(panel.frame.maxX == firstHost.bounds.maxX)
    _ = try await firstFrontend.evaluateJavaScript("WI._dockBottomTabBarButton.element.click(); void 0")
    try await wait { panel.dock == .bottom }
    #expect(firstFrontend.window === context.window)
    #expect(pages[0].webView.frame.minY == panel.frame.maxY)
    #expect(panel.frame.width == 340)
    if let path = ProcessInfo.processInfo.environment["BEND_INSPECTOR_SNAPSHOT"], let content = firstFrontend.window?.contentView {
        let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
    // Returning to the browser and focusing another pane routes to that page.
    context.window.makeKeyAndOrderFront(nil)
    store.focus(tab.pages[1].id)
    #expect(NSApp.sendAction(try #require(inspectorItem.action), to: inspectorItem.target, from: inspectorItem))
    try await wait { pages[1].webView.inspector.isVisible }
    #expect(try #require(NSApp.mainMenu).performKeyEquivalent(with: key))
    #expect((pages[1].webView.superview as? WebSurfaceHost)?.isDeveloperToolsVisible == false)
    #expect(pages[1].webView.frame.minY == 0)
    #expect(NSApp.sendAction(try #require(inspectorItem.action), to: inspectorItem.target, from: inspectorItem))
    try await wait { frontend(pages[1].webView)?.window === context.window }
    let secondFrontend = try #require(frontend(pages[1].webView))
    _ = try await secondFrontend.evaluateJavaScript("WI._closeTabBarButton.element.click(); void 0")
    try await wait { (pages[1].webView.superview as? WebSurfaceHost)?.isDeveloperToolsVisible == false }
    #expect((pages[1].webView.superview as? WebSurfaceHost)?.isDeveloperToolsVisible == false)
    // Closing the owning pane closes its inspector, even with the page retained here.
    store.closePage(tab.pages[0].id)
    try await wait { firstFrontend.window == nil }
    context.window.makeKeyAndOrderFront(nil)
    pages[1].navigate("browse://start")
    #expect(!delegate.validateMenuItem(console))
}
