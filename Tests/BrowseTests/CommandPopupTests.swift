import AppKit
import BrowseCore
import Testing
@testable import Browse

// @lat: [[lat.md/tests/commands-tests#Command popup actions]]
@Test @MainActor func commandPopupActions() throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendCommands-\(UUID())")
    let owner = BrowserWindows(root: root, persistentExtensions: false)
    owner.restore(show: false)
    let context = try #require(owner.active)
    let store = context.store
    let delegate = AppDelegate(browserWindows: owner)
    let oldMenu = NSApp.mainMenu
    defer {
        NSApp.mainMenu = oldMenu
        owner.prepareToQuit()
        for window in owner.windows { window.window.close() }
        try? FileManager.default.removeItem(at: root)
    }
    let pages = [Page(address: "https://example.com"), Page(address: "bend://guide")]
    var original = BrowserTab(title: "Split", pages: pages)
    original.focusedPane = pages[0].id
    original.layout = .split(id: UUID(), axis: .vertical, fraction: 0.35,
        first: .pane(pages[0].id), second: .pane(pages[1].id), isAutomatic: false)
    store.session.workspaces = [Workspace(name: "Tabs", tabs: [original])]
    store.session.selectedTab = original.id
    func command(_ id: String) throws -> PopupCommand {
        try #require(delegate.popupCommands().first { $0.id == id })
    }
    let commands = delegate.popupCommands()
    #expect(commands.count == 14)
    let historyIndex = try #require(commands.firstIndex { $0.id == "history" })
    #expect(commands[historyIndex + 1].id == "chat-history")
    try command("favorite").perform()
    #expect(store.favorite(for: store.selectedTab) != nil)
    #expect(try command("favorite").title == "Remove Tab from Favorites")
    try command("pinPane").perform()
    #expect(!((try command("close")).isEnabled))
    #expect(try command("pinTab").title == "Unpin Tab")
    #expect(try !command("returnPinned").isEnabled)
    let pinnedController = store.controller(for: store.selectedTab.pages[0])
    pinnedController.navigate("bend://history")
    #expect(try command("returnPinned").isEnabled)
    try command("returnPinned").perform()
    #expect(pinnedController.address == pages[0].address)
    pinnedController.webView.stopLoading()
    try command("duplicate").perform()
    let copy = store.selectedTab
    #expect(copy.id != original.id && copy.pages.map(\.address) == pages.map(\.address))
    #expect(Set(copy.pages.map(\.id)).isDisjoint(with: pages.map(\.id)))
    #expect(!copy.isPinned && copy.pages.allSatisfy { $0.favoriteID == nil })
    #expect(copy.focusedPane == copy.pages[0].id)
    if case .split(_, let axis, let fraction, _, _, let automatic) = copy.layout {
        #expect(axis == .vertical && fraction == 0.35 && automatic == false)
    } else { Issue.record("Duplicate lost its split layout") }
    #expect(store.session.workspaces[0].tabs.map(\.id) == [original.id, copy.id])
    store.select(original.id)
    try command("favorite").perform()
    try command("pinTab").perform()
    #expect(store.favorite(for: store.selectedTab) == nil && !store.selectedTab.isPinned)

    context.window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    context.window.makeKeyAndOrderFront(nil)
    delegate.installMenus()
    #expect(try command("chat").shortcut == "⇧⌘C")
    #expect(try command("close").shortcut == "⇧⌘W")
    #expect(try command("sidebar").shortcut == "⇧⌘S")
    #expect(try command("settings").shortcut == "⌘,")
    #expect(try command("print").shortcut == "⌘P")
    #expect(try command("history").shortcut == "⌘Y")
    #expect(try command("devTools").shortcut == "⇧⌘I")
    #expect(try command("duplicate").shortcut == nil)

    let menu = try #require(NSApp.mainMenu?.items.first { $0.title == "View" }?.submenu)
    let chatItem = try #require(menu.items.first { $0.action == #selector(AppDelegate.toggleChat) })
    #expect(chatItem.keyEquivalent == "c" && chatItem.keyEquivalentModifierMask == [.command, .shift])
    #expect(delegate.validateMenuItem(chatItem) && chatItem.title == "Show Chat")
    #expect(NSApp.sendAction(chatItem.action!, to: chatItem.target, from: chatItem))
    let chat = try #require(store.chats[store.selectedTab.id])
    #expect(store.openChats.contains(store.selectedTab.id))
    #expect(delegate.validateMenuItem(chatItem) && chatItem.title == "Hide Chat")
    #expect(NSApp.sendAction(chatItem.action!, to: chatItem.target, from: chatItem))
    #expect(!store.openChats.contains(store.selectedTab.id))
    #expect(store.chats[store.selectedTab.id] === chat)
    let item = try #require(menu.items.first { $0.title == "Show Commands…" })
    #expect(item.keyEquivalent == "p" && item.keyEquivalentModifierMask == [.command, .shift])
    #expect(NSApp.sendAction(item.action!, to: item.target, from: item))
    let panel = try #require(context.window.childWindows?.first { context.addressPanel.owns($0) })
    func descendants<T: NSView>(_ type: T.Type, _ view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, $0) }
    }
    let content = try #require(panel.contentView)
    let input = try #require(descendants(NSTextField.self, content).first { $0.isEditable })
    let table = try #require(descendants(NSTableView.self, content).first)
    #expect(table.numberOfRows == commands.count && input.stringValue.isEmpty)
    input.stringValue = "sidebar"
    context.addressPanel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: input))
    #expect(table.numberOfRows == 1)
    let shortcutRow = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
    #expect(descendants(NSTextField.self, shortcutRow).contains { $0.stringValue == "⇧⌘S" })

    let editor = try #require(input.currentEditor() as? NSTextView)
    #expect(context.addressPanel.control(input, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
    #expect(input.stringValue == "sidebar")
    let visible = store.sidebarVisible
    #expect(input.sendAction(input.action!, to: input.target))
    #expect(store.sidebarVisible != visible && !panel.isVisible)
    delegate.showCommands()
    input.stringValue = "no-such-action"
    context.addressPanel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: input))
    #expect(table.numberOfRows == 0)
    #expect(input.sendAction(input.action!, to: input.target))
    #expect(panel.isVisible)
    // A stale popup cannot act on a newly selected tab.
    input.stringValue = "close"
    context.addressPanel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: input))
    store.select(copy.id)
    #expect(input.sendAction(input.action!, to: input.target))
    #expect(store.session.workspaces[0].tabs.count == 2)
    context.addressPanel.dismiss(restoreFocus: false)
    store.newTab()
    let blankID = store.selectedTab.id
    delegate.showCommands()
    #expect(!context.addressPanel.cancelInitialEntryIfPresented())
    #expect(context.addressPanel.control(input, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
    #expect(!panel.isVisible && store.selectedTab.id == blankID)
}

// @lat: [[lat.md/tests/commands-tests#Automatic command shortcuts]]
@Test @MainActor func automaticCommandShortcuts() throws {
    _ = NSApplication.shared
    let oldMenu = NSApp.mainMenu
    defer { NSApp.mainMenu = oldMenu }
    let menu = NSMenu()
    let submenu = NSMenu()
    let parent = NSMenuItem(); parent.submenu = submenu; menu.addItem(parent)
    let selector = NSSelectorFromString("futureCommand:")
    let item = submenu.addItem(withTitle: "Future command", action: selector, keyEquivalent: "k")
    item.keyEquivalentModifierMask = [.control, .option, .command]
    NSApp.mainMenu = menu
    let command = PopupCommand(id: "future", title: "Future command", detail: "", icon: "star", menuAction: selector) {}
    #expect(command.shortcut == "⌃⌥⌘K")
    item.keyEquivalent = "\r"; item.keyEquivalentModifierMask = [.command, .shift]
    #expect(command.shortcut == "⇧⌘↩") // A binding change requires no palette edit.
    item.keyEquivalent = ""
    #expect(command.shortcut == nil)
    item.keyEquivalent = "q"; item.tag = 1
    #expect(command.shortcut == nil)
    let tagged = PopupCommand(id: "tagged", title: "Tagged command", detail: "", icon: "star", menuAction: selector, menuTag: 1) {}
    #expect(tagged.shortcut == "⇧⌘Q")
    item.isHidden = true
    #expect(tagged.shortcut == nil)
    #expect(MenuShortcut.label(key: "\u{f704}", modifiers: []) == "F1")
}
