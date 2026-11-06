import AppKit
import BrowseCore
import Testing
import WebKit
@testable import Browse

// @lat: [[tests#Find in page]]
@Test @MainActor func findInPage() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendFind-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let windows = BrowserWindows(root: root, persistentExtensions: false)
    windows.restore(show: false)
    let context = try #require(windows.active)
    let store = context.store
    let tab = BrowserTab(pages: [Page(address: "browse://start"), Page(address: "browse://start")])
    store.session.workspaces = [Workspace(name: "Test", tabs: [tab])]
    store.session.selectedTab = tab.id
    let pages = tab.pages.map { store.controller(for: $0) }
    let hosts = pages.map { _ in WebSurfaceHost(frame: NSRect(x: 0, y: 0, width: 600, height: 500)) }
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 500))
    for i in 0..<2 {
        hosts[i].frame.origin.x = CGFloat(i) * 600
        container.addSubview(hosts[i])
        hosts[i].update(webView: pages[i].webView, topContentInset: 36)
        pages[i].isStartPage = false
        pages[i].webView.loadHTMLString("""
            <p id="first">Findneedle first</p><div style="height:1000px"></div>
            <p id="second">findneedle second</p><div style="height:1000px"></div>
            <p id="third">FINDNEEDLE third</p>
            """, baseURL: nil)
    }
    context.window.contentView = container
    context.window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    context.window.makeKeyAndOrderFront(nil)
    context.window.makeKey()
    let delegate = AppDelegate(browserWindows: windows)
    let oldMenu = NSApp.mainMenu
    delegate.installMenus()
    defer {
        NSApp.mainMenu = oldMenu
        windows.prepareToQuit()
        for window in windows.windows { window.window.close() }
    }
    func settle() async throws { try await Task.sleep(for: .milliseconds(150)) }
    for page in pages {
        for _ in 0..<50 {
            if (try? await page.webView.evaluateJavaScript("document.getElementById('third') != null")) as? Bool == true { break }
            try await settle()
        }
        #expect(try await page.webView.evaluateJavaScript("document.getElementById('third') != null") as? Bool == true)
    }
    let edit = try #require(NSApp.mainMenu?.item(withTitle: "Edit")?.submenu)
    func command(_ title: String) throws {
        let item = try #require(edit.item(withTitle: title))
        #expect(delegate.validateMenuItem(item))
        #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
    }
    func fields(_ view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
    }
    func selectedID() async throws -> String {
        try #require(try await pages[0].webView.evaluateJavaScript("getSelection().anchorNode?.parentElement?.id ?? ''") as? String)
    }
    func waitForSelection(_ id: String) async throws {
        for _ in 0..<40 {
            if try await selectedID() == id { break }
            try await settle()
        }
        let actual = try await selectedID()
        #expect(actual == id)
    }
    // Invoke the actual menu shortcut, not merely the find controller.
    let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: context.window.windowNumber, context: nil,
        characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
    #expect(try #require(NSApp.mainMenu).performKeyEquivalent(with: key))
    #expect(hosts[0].isFindBarVisible)
    #expect(!hosts[1].isFindBarVisible)
    let bar = try #require(hosts[0].findBarView)
    let field = try #require(fields(bar).first { $0.isEditable })
    field.selectText(nil)
    let editor = try #require(field.currentEditor() as? NSTextView)
    editor.insertText("findneedle", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
    try await waitForSelection("first")
    try command("Find Next")
    try await waitForSelection("second")
    try command("Find Previous")
    try await waitForSelection("first")
    try command("Find Previous")
    try await waitForSelection("third")
    #expect((try await pages[0].webView.evaluateJavaScript("scrollY") as? Double ?? 0) > 0)
    #expect(try await pages[1].webView.evaluateJavaScript("getSelection().toString()") as? String == "")
    #expect(bar.frame.maxY == hosts[0].bounds.maxY - 36)
    if #available(macOS 26.0, *) {
        #expect(pages[0].webView.obscuredContentInsets.top == 36 + bar.frame.height)
    }
    // Return wraps forward from the last match while keeping the field active.
    field.selectText(nil)
    let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: context.window.windowNumber, context: nil,
        characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    context.window.sendEvent(enter)
    try await waitForSelection("first")
    let activeEditor = try #require(field.currentEditor() as? NSTextView)
    activeEditor.insertText("absentphrase", replacementRange: NSRange(location: 0, length: activeEditor.string.utf16.count))
    for _ in 0..<40 {
        if hosts[0].foundMatch == false { break }
        try await settle()
    }
    #expect(hosts[0].foundMatch == false)
    // Search stays usable at the minimum pane width, including its status label.
    hosts[0].frame.size.width = 250
    hosts[0].layoutSubtreeIfNeeded()
    bar.layoutSubtreeIfNeeded()
    #expect(field.frame.width > 40)
    #expect(field.convert(field.bounds, to: bar).minX >= 0)
    activeEditor.insertText("", replacementRange: NSRange(location: 0, length: activeEditor.string.utf16.count))
    try await settle()
    #expect(hosts[0].foundMatch == nil)
    hosts[0].frame.size.width = 600
    hosts[0].layoutSubtreeIfNeeded()
    store.focus(tab.pages[1].id)
    try command("Find in Page…")
    #expect(hosts[1].isFindBarVisible)
    hosts[1].performFindAction(.hideFindInterface)
    #expect(context.window.firstResponder === pages[1].webView)
    store.focus(tab.pages[0].id)
    try command("Find in Page…")
    field.selectText(nil)
    let escapeEditor = try #require(field.currentEditor() as? NSTextView)
    escapeEditor.insertText("findneedle", replacementRange: NSRange(location: 0, length: escapeEditor.string.utf16.count))
    let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: context.window.windowNumber, context: nil,
        characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
    context.window.sendEvent(escape)
    #expect(!hosts[0].isFindBarVisible)
    #expect(context.window.firstResponder === pages[0].webView)
    if #available(macOS 26.0, *) { #expect(pages[0].webView.obscuredContentInsets.top == 36) }
    pages[0].isStartPage = true
    #expect(!delegate.validateMenuItem(try #require(edit.item(withTitle: "Find in Page…"))))
}
