import Foundation
import AppKit
import Testing
import BrowseCore
@testable import Browse

// @lat: [[tests#Location popup requests]]
@Test @MainActor func locationPopupRequests() {
    let file = FileManager.default.temporaryDirectory
        .appendingPathComponent("BrowseTests-\(UUID())/session.json")
    let store = BrowserStore(sessionFile: file)
    var requested: [UUID] = []
    store.onAddressRequested = { requested.append($0) }

    let original = store.selectedTab.focusedPane
    store.requestAddress()
    #expect(requested == [original])

    for axis in [BrowseCore.SplitAxis.horizontal, .vertical] {
        store.split(axis)
        #expect(requested.last == store.selectedTab.focusedPane)
        #expect(store.selectedTab.focusedPane != original)
    }
    #expect(requested.count == 3)
    store.requestAddress(for: original)
    #expect(store.selectedTab.focusedPane == original)
    #expect(requested.last == original)
    store.requestAddress(for: UUID())
    #expect(requested.count == 4)

    store.newTab()
    #expect(requested.count == 5)
    #expect(requested.last == store.selectedTab.focusedPane)
    // Closing the final tab creates one replacement and requests its address.
    for tab in store.session.workspaces.flatMap(\.tabs) { store.closeTab(tab.id) }
    #expect(requested.count == 6)
    #expect(requested.last == store.selectedTab.focusedPane)

    let count = requested.count
    store.openPane(address: "https://example.com", toRightOf: store.selectedTab.focusedPane)
    store.newTab(address: "https://example.com/another")
    #expect(requested.count == count)
}

// @lat: [[tests#UI preference persistence]]
@Test @MainActor func uiPreferencePersistence() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BrowsePreferences-\(UUID())")
    let file = directory.appendingPathComponent("session.json")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // Legacy sessions omit the optional preference keys.
    let legacy = BrowserSession()
    try JSONEncoder().encode(legacy).write(to: file)
    let store = BrowserStore(sessionFile: file, persistentExtensions: false)
    #expect(store.selectedTab.id == legacy.selectedTab)
    #expect(store.commandClickDestination == .newPane)
    #expect(store.inactivePaneDimAmount == 0.08)
    #expect(store.windowGlass == .windowDefault)
    #expect(store.paneHeaderGlass == .headerDefault)
    store.commandClickDestination = .newTab
    store.inactivePaneDimAmount = 0.35
    store.windowGlass = GlassAppearance(clear: true, tint: .init(red: 0.2, green: 0.4, blue: 0.8), darkening: 0.15)
    store.paneHeaderGlass = GlassAppearance(tint: .init(red: 0.8, green: 0.3, blue: 0.1), darkening: 0.65)
    store.save()
    #expect(store.persistenceError == nil)
    let restored = BrowserStore(sessionFile: file, persistentExtensions: false)
    #expect(restored.commandClickDestination == .newTab)
    #expect(restored.inactivePaneDimAmount == 0.35)
    #expect(restored.windowGlass == store.windowGlass)
    #expect(restored.paneHeaderGlass == store.paneHeaderGlass)
    #expect(restored.selectedTab.id == legacy.selectedTab)
    store.inactivePaneDimAmount = -1
    #expect(store.inactivePaneDimAmount == 0)
    store.inactivePaneDimAmount = 2
    #expect(store.inactivePaneDimAmount == 1)
    store.inactivePaneDimAmount = .nan
    #expect(store.inactivePaneDimAmount == 1)
    store.session.inactivePaneDimAmount = -2
    #expect(store.inactivePaneDimAmount == 0)
    store.session.inactivePaneDimAmount = .infinity
    #expect(store.inactivePaneDimAmount == 0.08)
    store.windowGlass = GlassAppearance(tint: .init(red: -1, green: 2, blue: 0.5), darkening: 2)
    #expect(store.windowGlass.darkening == 1)
    #expect(store.windowGlass.tint == .init(red: 0, green: 1, blue: 0.5))
    store.paneHeaderGlass = GlassAppearance(tint: .init(red: .nan, green: 0, blue: 0), darkening: .infinity)
    #expect(store.paneHeaderGlass == .headerDefault)
    store.windowGlass = .windowDefault
    store.paneHeaderGlass = .headerDefault
    store.inactivePaneDimAmount = 0.08
    store.save()
    #expect(store.persistenceError == nil)
    let reset = BrowserStore(sessionFile: file, persistentExtensions: false)
    #expect(reset.windowGlass == .windowDefault)
    #expect(reset.paneHeaderGlass == .headerDefault)
}

// @lat: [[tests#Live window glass preferences]]
@Test @MainActor func liveWindowGlassPreferences() throws {
    guard #available(macOS 26.0, *) else { return }
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseGlass-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = BrowserStore(sessionFile: directory.appendingPathComponent("session.json"), persistentExtensions: false)
    let content = NSView()
    let glass = BrowserWindowGlass(store: store, content: content)
    #expect(glass.style == .regular)
    #expect(glass.tintColor == nil)
    store.windowGlass = GlassAppearance(clear: true, tint: .init(red: 0.1, green: 0.4, blue: 0.8))
    #expect(glass.style == .clear)
    let tint = try #require(glass.tintColor?.usingColorSpace(.sRGB))
    #expect(abs(tint.blueComponent - 0.8) < 0.001)
    store.paneHeaderGlass = GlassAppearance(darkening: 0.9)
    #expect(glass.style == .clear)
    #expect(glass.contentView === content)
    store.windowGlass = .windowDefault
    #expect(glass.style == .regular)
    #expect(glass.tintColor == nil)
    #expect(glass.contentView === content)
}

// @lat: [[tests#Canceling new tab entry]]
@Test @MainActor func cancelNewTabEntry() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseCancelTab-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    let original = store.selectedTab
    store.toggleZoom(original.focusedPane)
    store.newTab()
    let blank = store.selectedTab.focusedPane
    let cancelled = store.cancelNewTabEntry(for: blank)
    #expect(cancelled)
    #expect(store.selectedTab.id == original.id && store.selectedTab.layout == original.layout)
    #expect(store.zoomedPane == original.focusedPane)
    #expect(store.session.workspaces[0].tabs.count == 1)
    #expect(!store.canReopenClosed)
    store.save()
    let restored = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    #expect(restored.session.selectedTab == original.id && restored.session.workspaces[0].tabs.count == 1)
    // Existing tabs, completed entry, and panes added to a new tab are never discarded.
    #expect(!store.cancelNewTabEntry(for: original.focusedPane))
    store.newTab()
    let kept = store.selectedTab.focusedPane
    store.finishNewTabEntry(for: kept)
    #expect(!store.cancelNewTabEntry(for: kept))
    store.newTab()
    let split = store.selectedTab.focusedPane
    store.split(.horizontal)
    #expect(!store.cancelNewTabEntry(for: split))
    #expect(store.selectedTab.pages.count == 2)
    store.newTab(address: "https://example.com")
    #expect(!store.cancelNewTabEntry(for: store.selectedTab.focusedPane))
}

// @lat: [[tests#New tab popup keyboard cancellation]]
@Test @MainActor func newTabPopupKeyboardCancellation() throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseCancelPopup-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let windows = BrowserWindows(root: root, persistentExtensions: false)
    windows.restore(show: false)
    let context = try #require(windows.active)
    context.window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    context.window.makeKeyAndOrderFront(nil)
    let delegate = AppDelegate(browserWindows: windows)
    let oldMenu = NSApp.mainMenu
    delegate.installMenus()
    defer {
        NSApp.mainMenu = oldMenu
        windows.prepareToQuit(); for context in windows.windows { context.window.close() }
    }
    let store = context.store
    let original = store.selectedTab.id
    let file = try #require(NSApp.mainMenu?.item(withTitle: "File")?.submenu)
    func command(_ title: String) throws {
        let item = try #require(file.item(withTitle: title))
        #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
    }
    func popup() throws -> NSWindow {
        try #require(context.window.childWindows?.first { $0.title == "Open Location" && $0.isVisible })
    }
    func fields(_ view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
    }
    func escape(_ panel: NSWindow) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        NSApp.sendEvent(event)
    }
    for useEscape in [true, false] {
        try command("New Tab")
        #expect(store.session.workspaces[0].tabs.count == 2)
        let panel = try popup()
        let content = try #require(panel.contentView)
        let input = try #require(fields(content).first { $0.isEditable })
        let placeholder = try #require(input.placeholderAttributedString)
        let color = try #require(placeholder.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        #expect(try #require(color.usingColorSpace(.genericGray)).whiteComponent >= 0.7)
        // Editing without submitting still belongs to the provisional tab.
        input.stringValue = "changed my mind"
        if useEscape { try escape(panel) }
        else {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
                characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
            let handled = try #require(NSApp.mainMenu).performKeyEquivalent(with: event)
            #expect(handled)
        }
        #expect(!panel.isVisible)
        #expect(store.session.selectedTab == original && store.session.workspaces[0].tabs.count == 1)
        #expect(!store.canReopenClosed)
        // The command-line test host can remain inactive, so AppKit may deny
        // key-window status. Its browser responder must still be restored.
        #expect(context.window.firstResponder === context.window.contentView)
    }
    // Escape in an existing tab only dismisses location entry.
    try command("Open Location…")
    try escape(try popup())
    #expect(store.session.selectedTab == original && store.session.workspaces[0].tabs.count == 1)
    // Outside dismissal commits the blank tab: reopening its popup must not delete it.
    try command("New Tab")
    let retained = store.session.selectedTab
    context.addressPanel.dismiss(restoreFocus: true)
    try command("Open Location…")
    try escape(try popup())
    #expect(store.session.selectedTab == retained && store.session.workspaces[0].tabs.count == 2)
    // Successful submission also commits the tab, including internal destinations.
    try command("New Tab")
    let submitted = store.session.selectedTab
    let panel = try popup()
    let content = try #require(panel.contentView)
    let input = try #require(fields(content).first { $0.isEditable })
    input.stringValue = "browse://guide"
    #expect(input.sendAction(try #require(input.action), to: input.target))
    #expect(!panel.isVisible)
    #expect(store.controller(for: store.selectedTab.pages[0]).address == "browse://guide")
    try command("Open Location…")
    try escape(try popup())
    #expect(store.session.selectedTab == submitted && store.session.workspaces[0].tabs.count == 3)
}
