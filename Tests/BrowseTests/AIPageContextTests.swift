import AppKit
import AI
import BrowseCore
import Testing
@testable import Browse

// @lat: [[lat.md/tests/ai-tests#Selection and screenshot approval]]
@Test @MainActor func aiPageContextApproval() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let domain = "AIContext-\(UUID())"
    let defaults = UserDefaults(suiteName: domain)!
    let settings = AISettings(defaults: defaults)
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    let page = Page(address: "https://example.com/context")
    let tab = BrowserTab(title: "Context", pages: [page])
    store.session.workspaces = [Workspace(name: "Context", tabs: [tab])]; store.session.selectedTab = tab.id
    let controller = store.controller(for: page)
    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 500, height: 350), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = controller.webView; window.orderFront(nil)
    defer { window.close(); store.stopWindow(); defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: root) }
    controller.webView.loadHTMLString("<body><p id='chosen'>Selected fact</p><p id='other'>Other fact</p><div contenteditable id='draft'>Private draft</div></body>", baseURL: URL(string: page.address))
    for _ in 0..<300 {
        if controller.webView.url != nil && !controller.webView.isLoading { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    func select(_ id: String) async throws {
        _ = try await controller.webView.evaluateJavaScript("var r=document.createRange();r.selectNodeContents(document.getElementById('\(id)'));getSelection().removeAllRanges();getSelection().addRange(r)")
    }
    #expect(try await controller.selectedPageText().isEmpty)
    try await select("chosen")
    #expect(try await controller.selectedPageText() == "Selected fact")
    try await select("draft")
    #expect(try await controller.selectedPageText().isEmpty)
    try await select("chosen")
    let approval = AIActionApproval()
    let tools = PaneChatTools(store: store, tabID: tab.id, settings: settings, approve: approval.request)
    func pending() async throws -> AIActionApproval.Request {
        for _ in 0..<100 where approval.pending == nil { try await Task.sleep(for: .milliseconds(10)) }
        return try #require(approval.pending)
    }
    for name in ["get_selected_text", "take_screenshot"] {
        let task = Task { try await tools.execute(name, input: .init(pane: page.id.uuidString)) }
        let request = try await pending()
        #expect(request.action.rawValue == name)
        approval.resolve(request.id, approved: false)
        await #expect(throws: Error.self) { try await task.value }
    }
    let selection = Task { try await tools.execute("get_selected_text", input: .init(pane: page.id.uuidString)) }
    let request = try await pending()
    try await select("other") // Acquisition happens after approval, not when proposed.
    approval.resolve(request.id, approved: true)
    #expect(try await selection.value["text"] == .string("Other fact"))
    let screenshot = Task { try await tools.execute("take_screenshot", input: .init(pane: page.id.uuidString)) }
    let shotRequest = try await pending()
    let preview = try #require(shotRequest.screenshot)
    _ = try await controller.webView.evaluateJavaScript("document.body.style.backgroundColor='red'")
    approval.resolve(shotRequest.id, approved: true)
    let screenshotResult = try await screenshot.value
    let encoded = try #require(screenshotResult["image"]?.string)
    let data = try #require(Data(base64Encoded: encoded))
    #expect(data == preview)
    let bitmap = try #require(NSBitmapImageRep(data: data))
    #expect(bitmap.pixelsWide > 0 && bitmap.pixelsWide <= 1440)
    for name in ["get_selected_text", "take_screenshot"] {
        let task = Task { try await tools.execute(name, input: .init(pane: page.id.uuidString)) }
        let request = try await pending()
        settings.setToolEnabled(name, enabled: false)
        approval.resolve(request.id, approved: true)
        await #expect(throws: Error.self) { try await task.value }
        settings.setToolEnabled(name, enabled: true)
    }
    let stale = Task { try await tools.execute("get_selected_text", input: .init(pane: page.id.uuidString)) }
    let staleRequest = try await pending()
    controller.webView(controller.webView, didStartProvisionalNavigation: nil)
    approval.resolve(staleRequest.id, approved: true)
    await #expect(throws: Error.self) { try await stale.value }
    let compact = PaneChatTools(store: store, tabID: tab.id, settings: settings, compactReads: true)
    #expect(!compact.tools().contains { $0.definition.name == "take_screenshot" })
}

// @lat: [[lat.md/tests/ai-tests#Selection focus retention]]
@Test @MainActor func pageSelectionFocusRetention() async throws {
    _ = NSApplication.shared
    let page = PageController(address: "https://example.com/selection")
    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 600, height: 400),
        styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    page.webView.frame = NSRect(x: 0, y: 100, width: 600, height: 300)
    let input = ChatComposerTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 90))
    host.addSubview(page.webView); host.addSubview(input)
    window.contentView = host; window.makeKeyAndOrderFront(nil)
    defer { page.webView.stopLoading(); window.close() }
    page.webView.loadHTMLString("<div id='selected'>Remember this passage<img id='picture' width='80' height='40' src='data:image/svg+xml,%3Csvg xmlns=%22http://www.w3.org/2000/svg%22 width=%2280%22 height=%2240%22%3E%3Crect width=%2280%22 height=%2240%22 fill=%22red%22/%3E%3C/svg%3E'></div>", baseURL: URL(string: page.address))
    for _ in 0..<300 {
        if page.webView.url != nil && !page.webView.isLoading { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    for imageOnly in [false, true] {
        #expect(window.makeFirstResponder(page.webView))
        let select = imageOnly ? "r.selectNode(document.getElementById('picture'))" : "r.selectNodeContents(document.getElementById('selected'))"
        _ = try await page.webView.evaluateJavaScript("var r=document.createRange();\(select);getSelection().removeAllRanges();getSelection().addRange(r)")
        #expect(window.makeFirstResponder(input))
        input.insertText("Explain what I selected", replacementRange: NSRange(location: 0, length: input.string.utf16.count))
        try await Task.sleep(for: .milliseconds(100))
        // Assert WebKit's real range survived, including the image. No cached
        // text, custom highlight, or forced range restoration can satisfy this.
        let hasImage = try await page.webView.evaluateJavaScript("!getSelection().isCollapsed && getSelection().getRangeAt(0).cloneContents().querySelectorAll('img').length === 1")
        #expect(hasImage as? Bool == true)
        #expect(try await page.selectedPageText() == (imageOnly ? "" : "Remember this passage"))
        #expect(window.firstResponder === input)
        #expect(input.string == "Explain what I selected")
        #expect(window.makeFirstResponder(page.webView))
        _ = try await page.webView.evaluateJavaScript("getSelection().removeAllRanges()")
        #expect(try await page.selectedPageText().isEmpty)
        let collapsed = try await page.webView.evaluateJavaScript("getSelection().isCollapsed")
        #expect(collapsed as? Bool == true)
    }
    page.navigate("bend://start")
    #expect(try await page.selectedPageText().isEmpty)
}
