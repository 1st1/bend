import AppKit
import Combine
import Testing
import WebKit
import BrowseCore
@testable import Browse

// @lat: [[tests#Independent browser windows]]
@Test @MainActor func independentBrowserWindows() throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseWindows-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let owner = BrowserWindows(root: root, persistentExtensions: false)
    owner.restore(show: false)
    defer { owner.prepareToQuit(); for context in owner.windows { context.window.close() } }
    let first = try #require(owner.active)
    let firstSelection = first.store.session.selectedTab
    let second = owner.newWindow(show: false)
    #expect(first.window !== second.window)
    #expect(first.addressPanel !== second.addressPanel)
    #expect(second.store.session.workspaces.flatMap(\.tabs).count == 1)
    #expect(second.store.selectedTab.pages.count == 1)
    #expect(second.store.selectedTab.pages[0].address == "browse://start")
    second.store.newTab()
    #expect(first.store.session.selectedTab == firstSelection)
    #expect(first.store.session.workspaces.flatMap(\.tabs).count == 1)
    #expect(second.store.session.workspaces.flatMap(\.tabs).count == 2)

    var historyUpdates = 0
    let observation = second.store.historyPublisher.dropFirst().sink { _ in historyUpdates += 1 }
    first.store.recordVisit(url: "https://example.com/one", title: "One")
    second.store.recordVisit(url: "https://example.com/two", title: "Two")
    #expect(first.store.history == second.store.history)
    #expect(first.store.history.visits.count == 2)
    #expect(historyUpdates == 2)
    second.store.removeHistory(url: "https://example.com/one")
    #expect(first.store.history.visits.count == 1)
    withExtendedLifetime(observation) {}
    second.store.commandClickDestination = .newTab
    second.store.inactivePaneDimAmount = 0.35
    #expect(first.store.commandClickDestination == .newTab)
    #expect(first.store.inactivePaneDimAmount == 0.35)
    if #available(macOS 26.0, *) {
        let glass = try #require(second.window.contentView as? BrowserWindowGlass)
        first.store.windowGlass = GlassAppearance(clear: true)
        #expect(glass.style == .clear)
    }
    if #available(macOS 15.4, *) {
        let manager = first.store.extensions
        #expect(manager === second.store.extensions)
        #expect(manager.browserWindows.count == 2)
        let page = second.store.selectedTab.pages[0]
        let adapter = try #require(manager.tabs[page.id])
        #expect(adapter.store === second.store)
        #expect(manager.window(for: second.store).native === second.window)
        let controller = second.store.controller(for: page)
        first.window.close()
        #expect(manager.browserWindows.count == 1)
        #expect(manager.tabs[page.id] === adapter)
        #expect(second.store.existingController(for: page.id) === controller)
        #expect(manager.pages.count == second.store.session.workspaces.flatMap(\.tabs).flatMap(\.pages).count)
    }
}

// @lat: [[tests#Browser window restoration]]
@Test @MainActor func browserWindowRestoration() throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseWindowsRestore-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let owner = BrowserWindows(root: root, persistentExtensions: false)
    owner.restore(show: false)
    let first = try #require(owner.active)
    let second = owner.newWindow(show: false)
    second.store.split(.vertical)
    second.store.commandClickDestination = .newTab
    second.store.recordVisit(url: "https://example.com/", title: "Example")
    let savedLayout = second.store.selectedTab.layout
    let savedSelection = second.store.session.selectedTab
    owner.prepareToQuit()
    first.window.close(); second.window.close()
    let restored = BrowserWindows(root: root, persistentExtensions: false)
    restored.restore(show: false)
    #expect(restored.windows.map(\.id) == [first.id, second.id])
    let restoredSecond = try #require(restored.windows.last)
    #expect(restoredSecond.store.session.selectedTab == savedSelection)
    #expect(restoredSecond.store.selectedTab.layout == savedLayout)
    #expect(restoredSecond.store.commandClickDestination == .newTab)
    #expect(restoredSecond.store.history.visits.count == 1)
    restored.windows[0].window.close()
    // Closing one window removes it from the next launch, but closing the final
    // one preserves it. Preferences still persist after the legacy window closes.
    restoredSecond.store.inactivePaneDimAmount = 0.42
    restoredSecond.window.close()
    restored.prepareToQuit()
    let final = BrowserWindows(root: root, persistentExtensions: false)
    final.restore(show: false)
    defer { final.prepareToQuit(); for context in final.windows { context.window.close() } }
    #expect(final.windows.map(\.id) == [second.id])
    #expect(final.active?.store.selectedTab.layout == savedLayout)
    #expect(final.active?.store.inactivePaneDimAmount == 0.42)
    if #available(macOS 15.4, *) {
        let manager = final.sharedStore.extensions
        let oldAdapter = try #require(manager.browserWindows.first)
        final.windows[0].window.close()
        #expect(manager.pages.isEmpty)
        let reopened = final.newWindow(show: false)
        #expect(manager.browserWindows.count == 1)
        #expect(manager.browserWindows[0] !== oldAdapter)
        #expect(oldAdapter.store == nil)
        #expect(manager.window(for: reopened.store).native === reopened.window)
    }
}

// @lat: [[tests#New window keyboard command]]
@Test @MainActor func newWindowKeyboardCommand() throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseWindowCommand-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let owner = BrowserWindows(root: root, persistentExtensions: false)
    owner.restore(show: false)
    let delegate = AppDelegate(browserWindows: owner)
    let previousMenu = NSApp.mainMenu
    delegate.installMenus()
    defer {
        NSApp.mainMenu = previousMenu
        owner.prepareToQuit(); for context in owner.windows { context.window.close() }
    }
    let first = try #require(owner.active)
    let menu = try #require(NSApp.mainMenu)
    let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
        timestamp: 0, windowNumber: first.window.windowNumber, context: nil,
        characters: "n", charactersIgnoringModifiers: "n", isARepeat: false, keyCode: 45))
    let handled = menu.performKeyEquivalent(with: event)
    #expect(handled)
    #expect(owner.windows.count == 2)
    let second = try #require(owner.windows.last)
    second.window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    #expect(owner.active === second)
    second.addressPanel.dismiss(restoreFocus: false)
    let file = try #require(menu.item(withTitle: "File")?.submenu)
    let tabCommand = try #require(file.item(withTitle: "New Tab"))
    #expect(NSApp.sendAction(try #require(tabCommand.action), to: tabCommand.target, from: tabCommand))
    #expect(second.store.session.workspaces.flatMap(\.tabs).count == 2)
    #expect(first.store.session.workspaces.flatMap(\.tabs).count == 1)
    first.window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    first.window.makeKeyAndOrderFront(nil)
    #expect(owner.active === first)
    #expect(NSApp.sendAction(try #require(tabCommand.action), to: tabCommand.target, from: tabCommand))
    #expect(first.store.session.workspaces.flatMap(\.tabs).count == 2)
    #expect(second.store.session.workspaces.flatMap(\.tabs).count == 2)
}
