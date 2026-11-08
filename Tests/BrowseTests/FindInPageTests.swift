import AppKit
import SwiftUI
import BrowseCore
import Testing
import WebKit
@testable import Browse

// @lat: [[tests#Find in page]]
@Test @MainActor func findInPage() async throws {
    _ = NSApplication.shared
    // An unhandled Escape must also be safe before the web view is mounted.
    FocusWebView(frame: .zero, configuration: WKWebViewConfiguration()).cancelOperation(nil)
    WebSurfaceHost(frame: .zero).cancelOperation(nil)
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
        hosts[i].update(webView: pages[i].webView, topContentInset: 36, headerAppearance: .headerDefault)
        pages[i].isStartPage = false
        pages[i].webView.loadHTMLString("""
            <p id="first">Findneedle first</p><div style="height:1000px"></div>
            <p id="second">findneedle second</p><div style="height:1000px"></div>
            <p id="third">FINDNEEDLE third</p>
            <p hidden>findneedle hidden</p>
            <iframe srcdoc="<p>frameword one</p><p>frameword two</p>"></iframe>
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
        ((view as? NSTextField).map { [$0] } ?? []) + view.subviews.flatMap(fields)
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
    func waitForCount(_ count: Int) async throws {
        for _ in 0..<40 {
            if hosts[0].matchCount == count { break }
            try await settle()
        }
        #expect(hosts[0].matchCount == count)
    }
    // Invoke the actual menu shortcut, not merely the find controller.
    let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: context.window.windowNumber, context: nil,
        characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
    #expect(try #require(NSApp.mainMenu).performKeyEquivalent(with: key))
    #expect(hosts[0].isFindBarVisible)
    #expect(!hosts[1].isFindBarVisible)
    let bar = try #require(hosts[0].findBarView)
    func buttonHosts(in view: NSView) -> [NSHostingView<FindToolbarButtons>] {
        (view as? NSHostingView<FindToolbarButtons>).map { [$0] } ?? view.subviews.flatMap { buttonHosts(in: $0) }
    }
    let buttons = try #require(buttonHosts(in: bar).first)
    func clickFindButton(_ index: Int) async throws {
        let point = buttons.convert(NSPoint(x: 12 + 24 * index, y: 12), to: nil)
        try sendPaneMouse(.leftMouseDown, at: point, to: context.window)
        try sendPaneMouse(.leftMouseUp, at: point, to: context.window)
        try await settle()
    }
    let field = try #require(fields(bar).first { $0.isEditable })
    bar.layoutSubtreeIfNeeded()
    let emptyInputFrame = field.frame
    field.selectText(nil)
    let editor = try #require(field.currentEditor() as? NSTextView)
    func checkEmptyEditor(_ editor: NSTextView) throws {
        let cell = try #require(field.cell as? NSSearchFieldCell)
        let icon = cell.searchButtonRect(forBounds: field.bounds)
        let screenCaret = editor.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
        let caret = field.convert(context.window.convertFromScreen(screenCaret), from: nil)
        #expect(caret.minX >= icon.maxX)
        #expect(caret.minY >= 0 && caret.maxY <= field.bounds.height)
        let editorRect = editor.convert(editor.visibleRect, to: field)
        #expect(abs(editorRect.midY - field.bounds.midY) <= 2)
    }
    try checkEmptyEditor(editor)
    editor.insertText("findneedle", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
    try await waitForSelection("first")
    try await waitForCount(3)
    #expect(fields(bar).contains { $0.stringValue == "3 matches" })
    bar.layoutSubtreeIfNeeded()
    let countLabel = try #require(fields(field).first { $0.stringValue == "3 matches" })
    #expect(countLabel.superview === field)
    #expect(countLabel.alignment == .right)
    #expect(field.bounds.contains(countLabel.frame))
    let searchCell = try #require(field.cell as? NSSearchFieldCell)
    #expect(searchCell.searchTextRect(forBounds: field.bounds).maxX < countLabel.frame.minX)
    #expect(editor.convert(editor.visibleRect, to: field).maxX <= countLabel.frame.minX)
    #expect(field.frame == emptyInputFrame)
    try command("Find Next")
    #expect(hosts[0].matchCount == 3)
    #expect(countLabel.stringValue == "3 matches")
    bar.layoutSubtreeIfNeeded()
    #expect(field.frame == emptyInputFrame)
    try await waitForSelection("second")
    #expect(countLabel.stringValue == "3 matches")
    try command("Find Previous")
    try await waitForSelection("first")
    try command("Find Previous")
    try await waitForSelection("third")
    #expect((try await pages[0].webView.evaluateJavaScript("scrollY") as? Double ?? 0) > 0)
    #expect(try await pages[1].webView.evaluateJavaScript("getSelection().toString()") as? String == "")
    #expect(bar.convert(bar.bounds, to: hosts[0]).maxY == hosts[0].bounds.maxY - 36)
    if #available(macOS 26.0, *) {
        #expect(pages[0].webView.obscuredContentInsets.top == 36 + bar.frame.height)
        let chromeContent = try #require(bar.superview)
        let glass = try #require(hosts[0].subviews.flatMap(\.subviews).compactMap { $0 as? NSGlassEffectView }.first)
        let clip = try #require(glass.superview)
        #expect(clip.layer?.masksToBounds == true)
        #expect(chromeContent.superview === glass.contentView)
        #expect(!(bar is NSVisualEffectView))
        #expect(clip.frame.height == 36 + bar.frame.height)
        #expect(clip.frame.maxY == hosts[0].bounds.maxY)
        #expect(glass.frame.minY < clip.bounds.minY)
        #expect(glass.frame.maxY > clip.bounds.maxY)
        #expect(glass.frame.minX == clip.bounds.minX)
        #expect(glass.frame.maxX == clip.bounds.maxX)
        #expect(chromeContent.convert(chromeContent.bounds, to: clip) == clip.bounds)
        let editorBeforeAppearanceChange = context.window.firstResponder
        hosts[0].update(webView: pages[0].webView, topContentInset: 36,
                        headerAppearance: GlassAppearance(clear: true, tint: .init(red: 0.2, green: 0.4, blue: 0.8), darkening: 0.3))
        #expect(glass.style == .clear)
        #expect(glass.tintColor != nil)
        #expect(context.window.firstResponder === editorBeforeAppearanceChange)
        #expect(bar.superview === chromeContent)
        let activeTint = NSColor.systemBlue.withAlphaComponent(0.4)
        hosts[0].update(webView: pages[0].webView, topContentInset: 36,
            headerAppearance: .headerDefault, activeHeaderTint: activeTint)
        let tint = hosts[0].activeHeaderTintView
        #expect(tint.superview === chromeContent)
        #expect(tint.frame == chromeContent.bounds)
        #expect(tint.layer?.backgroundColor == activeTint.cgColor)
        #expect(tint.frame.contains(bar.frame))
        #expect(context.window.firstResponder === editorBeforeAppearanceChange)
        #expect(hosts[1].activeHeaderTintView.layer?.backgroundColor == nil)
        hosts[0].update(webView: pages[0].webView, topContentInset: 36, headerAppearance: .headerDefault)
        #expect(tint.layer?.backgroundColor == nil)
        #expect(bar.superview === chromeContent)
        let originalBarFrame = bar.convert(bar.bounds, to: hosts[0])
        for (top, bottom) in [(0.0, 0.0), (0.5, 1.25), (2.5, 8.0), (16.0, 16.0)] {
            hosts[0].update(webView: pages[0].webView, topContentInset: 36,
                            headerAppearance: .headerDefault, topRimClipping: top, bottomRimClipping: bottom)
            #expect(abs(glass.frame.maxY - clip.bounds.maxY - top) < 0.01)
            #expect(abs(glass.frame.minY - clip.bounds.minY + bottom) < 0.01)
            #expect(bar.convert(bar.bounds, to: hosts[0]) == originalBarFrame)
            #expect(pages[0].webView.obscuredContentInsets.top == clip.frame.height)
            #expect(context.window.firstResponder === editorBeforeAppearanceChange)
        }
    }
    try await clickFindButton(1)
    try await waitForSelection("first")
    try await clickFindButton(0)
    try await waitForSelection("third")
    // Return wraps forward from the last match while keeping the field active.
    field.selectText(nil)
    let enter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: context.window.windowNumber, context: nil,
        characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    context.window.sendEvent(enter)
    #expect(hosts[0].matchCount == 3)
    #expect(countLabel.stringValue == "3 matches")
    try await waitForSelection("first")
    #expect(countLabel.stringValue == "3 matches")
    let activeEditor = try #require(field.currentEditor() as? NSTextView)
    activeEditor.insertText(String(repeating: "absentphrase", count: 20), replacementRange: NSRange(location: 0, length: activeEditor.string.utf16.count))
    #expect(hosts[0].matchCount == nil)
    #expect(countLabel.stringValue.isEmpty)
    for _ in 0..<40 {
        if hosts[0].foundMatch == false { break }
        try await settle()
    }
    #expect(hosts[0].foundMatch == false)
    try await waitForCount(0)
    #expect(activeEditor.convert(activeEditor.visibleRect, to: field).maxX <= countLabel.frame.minX)
    bar.layoutSubtreeIfNeeded()
    #expect(field.frame == emptyInputFrame)
    // Search stays usable at the minimum pane width, including its status label.
    hosts[0].frame.size.width = 250
    hosts[0].layoutSubtreeIfNeeded()
    bar.layoutSubtreeIfNeeded()
    #expect(field.frame.width > 40)
    #expect(field.convert(field.bounds, to: bar).minX >= 0)
    #expect(searchCell.searchTextRect(forBounds: field.bounds).width > 20)
    #expect(searchCell.searchTextRect(forBounds: field.bounds).maxX < countLabel.frame.minX)
    let narrowInputFrame = field.frame
    activeEditor.insertText("", replacementRange: NSRange(location: 0, length: activeEditor.string.utf16.count))
    try await settle()
    #expect(hosts[0].foundMatch == nil)
    #expect(hosts[0].matchCount == nil)
    bar.layoutSubtreeIfNeeded()
    #expect(field.frame == narrowInputFrame)
    try checkEmptyEditor(activeEditor)
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
    if #available(macOS 26.0, *) {
        #expect(pages[0].webView.obscuredContentInsets.top == 36)
        let tint = hosts[0].activeHeaderTintView
        #expect(tint.convert(tint.bounds, to: hosts[0]) == NSRect(x: 0, y: hosts[0].bounds.maxY - 36,
                                                               width: hosts[0].bounds.width, height: 36))
    }
    // Escape clears both the native find selection and obsolete count replies,
    // even when it arrives immediately after a new query.
    try await waitForSelection("")
    #expect(hosts[0].matchCount == nil)
    let scrollAfterDismiss = try await pages[0].webView.evaluateJavaScript("scrollY") as? Double
    try await settle()
    #expect(try await pages[0].webView.evaluateJavaScript("scrollY") as? Double == scrollAfterDismiss)
    // Once the field closes, subsequent Escape presses go through WebKit's
    // asynchronous command fallback. The page still receives its key events.
    _ = try await pages[0].webView.evaluateJavaScript("""
        window.escapeCount = 0;
        document.addEventListener('keydown', event => {
            if (event.key === 'Escape') window.escapeCount++;
        });
        """)
    for _ in 0..<3 {
        context.window.sendEvent(escape)
        try await settle()
    }
    for _ in 0..<40 {
        if try await pages[0].webView.evaluateJavaScript("window.escapeCount") as? Int == 3 { break }
        try await settle()
    }
    #expect(try await pages[0].webView.evaluateJavaScript("window.escapeCount") as? Int == 3)
    #expect(!hosts[0].isFindBarVisible)
    pages[0].webView.cancelOperation(nil)
    hosts[0].cancelOperation(nil)
    try command("Find in Page…")
    try await waitForCount(3)
    let frameEditor = try #require(field.currentEditor() as? NSTextView)
    frameEditor.insertText("frameword", replacementRange: NSRange(location: 0, length: frameEditor.string.utf16.count))
    try await waitForCount(2)
    #expect(try await pages[0].webView.evaluateJavaScript("frames[0].getSelection().toString().toLowerCase()") as? String == "frameword")
    try await clickFindButton(2)
    #expect(!hosts[0].isFindBarVisible)
    #expect(context.window.firstResponder === pages[0].webView)
    for _ in 0..<40 {
        if try await pages[0].webView.evaluateJavaScript("frames[0].getSelection().toString()") as? String == "" { break }
        try await settle()
    }
    #expect(try await pages[0].webView.evaluateJavaScript("frames[0].getSelection().toString()") as? String == "")
    #expect(hosts[0].matchCount == nil)
    pages[0].isStartPage = true
    #expect(!delegate.validateMenuItem(try #require(edit.item(withTitle: "Find in Page…"))))
}
