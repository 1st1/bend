import AppKit
import BrowseCore
import Testing
import WebKit
@testable import Browse

// @lat: [[lat.md/tests/web-pages-tests#Page printing]]
@Test @MainActor func pagePrinting() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendPrinting-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let windows = BrowserWindows(root: root, persistentExtensions: false)
    windows.restore(show: false)
    let context = try #require(windows.active)
    let store = context.store
    let tab = BrowserTab(pages: [Page(address: "browse://start"), Page(address: "browse://start")])
    store.session.workspaces = [Workspace(name: "Print test", tabs: [tab])]
    store.session.selectedTab = tab.id
    let pages = tab.pages.map { store.controller(for: $0) }
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 500))
    for (index, page) in pages.enumerated() {
        let host = WebSurfaceHost(frame: NSRect(x: index * 500, y: 0, width: 500, height: 500))
        content.addSubview(host)
        host.update(webView: page.webView, topContentInset: 36)
        page.isStartPage = false
        page.webView.loadHTMLString("<title>Print pane \(index)</title><h1>Printable page \(index)</h1><input value='keep me'>", baseURL: nil)
    }
    context.window.contentView = content
    context.window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    context.window.makeKeyAndOrderFront(nil)
    var focusedWindow: NSWindow? = context.window
    let delegate = AppDelegate(browserWindows: windows, focusedWindow: { focusedWindow })
    let oldMenu = NSApp.mainMenu
    delegate.installMenus()
    defer {
        if let sheet = context.window.attachedSheet { context.window.endSheet(sheet, returnCode: .cancel) }
        NSApp.mainMenu = oldMenu
        windows.prepareToQuit()
        for session in windows.windows { session.window.close() }
    }
    for (index, page) in pages.enumerated() {
        for _ in 0..<100 {
            if page.title == "Print pane \(index)", !page.webView.isLoading,
               (try? await page.webView.evaluateJavaScript("document.querySelector('input') != null")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(page.title == "Print pane \(index)")
    }
    let file = try #require(NSApp.mainMenu?.item(withTitle: "File")?.submenu)
    let printItem = try #require(file.item(withTitle: "Print…"))
    #expect(printItem.keyEquivalent == "p")
    #expect(printItem.keyEquivalentModifierMask == .command)

    // Show and cancel real print sheets; never submit a job to a printer.
    for index in [1, 0] {
        store.focus(tab.pages[index].id)
        #expect(delegate.validateMenuItem(printItem))
        if index == 1 {
            let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: 0, windowNumber: context.window.windowNumber, context: nil,
                characters: "p", charactersIgnoringModifiers: "p", isARepeat: false, keyCode: 35))
            #expect(try #require(NSApp.mainMenu).performKeyEquivalent(with: key))
        } else {
            #expect(NSApp.sendAction(try #require(printItem.action), to: printItem.target, from: printItem))
        }
        let operation = try #require(delegate.printOperation)
        #expect(operation.jobTitle == "Print pane \(index)")
        #expect(operation.showsPrintPanel)
        for _ in 0..<100 where context.window.attachedSheet == nil { try await Task.sleep(for: .milliseconds(20)) }
        let sheet = try #require(context.window.attachedSheet)
        #expect(NSApp.modalWindow == nil)
        #expect(!delegate.validateMenuItem(printItem))
        delegate.printPage()
        #expect(delegate.printOperation === operation)
        context.window.endSheet(sheet, returnCode: .cancel)
        for _ in 0..<100 where delegate.printOperation != nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(delegate.printOperation == nil)
        #expect(try await pages[index].webView.evaluateJavaScript("document.querySelector('input').value") as? String == "keep me")
    }
    pages[0].isStartPage = true
    #expect(!delegate.validateMenuItem(printItem))
    pages[0].isStartPage = false
    pages[0].error = "Load failed"
    #expect(!delegate.validateMenuItem(printItem))
    pages[0].error = nil
    content.isHidden = true
    #expect(!delegate.validateMenuItem(printItem))
    content.isHidden = false
    let utility = NSWindow()
    utility.isReleasedWhenClosed = false
    focusedWindow = utility
    #expect(!delegate.validateMenuItem(printItem))
    delegate.printPage()
    #expect(delegate.printOperation == nil)
}
