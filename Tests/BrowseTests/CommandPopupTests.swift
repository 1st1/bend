import AppKit
import BrowseCore
import Testing
@testable import Browse

// @lat: [[tests#Command popup actions]]
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
    let pages = [Page(address: "https://example.com"), Page(address: "browse://guide")]
    var original = BrowserTab(title: "Split", pages: pages)
    original.focusedPane = pages[0].id
    original.layout = .split(id: UUID(), axis: .vertical, fraction: 0.35,
        first: .pane(pages[0].id), second: .pane(pages[1].id), isAutomatic: false)
    store.session.workspaces = [Workspace(name: "Tabs", tabs: [original])]
    store.session.selectedTab = original.id
    func command(_ id: String) throws -> PopupCommand {
        try #require(delegate.popupCommands().first { $0.id == id })
    }
    #expect(delegate.popupCommands().count == 10)
    try command("favorite").perform()
    #expect(store.favorite(for: store.selectedTab) != nil)
    #expect(try command("favorite").title == "Remove Tab from Favorites")
    try command("pinPane").perform()
    #expect(!((try command("close")).isEnabled))
    #expect(try command("pinTab").title == "Unpin Tab")
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
    let menu = try #require(NSApp.mainMenu?.items.first { $0.title == "View" }?.submenu)
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
    #expect(table.numberOfRows == 10 && input.stringValue.isEmpty)
    input.stringValue = "sidebar"
    context.addressPanel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: input))
    #expect(table.numberOfRows == 1)
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
