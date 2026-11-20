import AppKit
import Testing
import BrowseCore
@testable import Browse

@MainActor private final class RecentTabFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseRecentTabs-\(UUID())")
    let owner: BrowserWindows
    let context: BrowserWindowSession
    let ids: [UUID]
    var store: BrowserStore { context.store }

    init() throws {
        _ = NSApplication.shared
        owner = BrowserWindows(root: root, persistentExtensions: false)
        owner.restore(show: false)
        context = try #require(owner.active)
        context.addressPanel.dismiss(restoreFocus: false)
        context.window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        let tabs = (1...4).map { BrowserTab(title: "Tab \($0)", pages: [Page(address: "about:blank")]) }
        ids = tabs.map(\.id)
        context.store.session.workspaces = [Workspace(name: "Test", tabs: tabs)]
        for id in ids { context.store.select(id) }
    }

    func tearDown() {
        owner.prepareToQuit(); for context in owner.windows { context.window.close() }
        try? FileManager.default.removeItem(at: root)
    }

    /// Presses Control-Tab, or Control-Shift-Tab, in `window` (the browser window by default).
    func press(shift: Bool = false, in window: NSWindow? = nil) throws {
        let window = window ?? context.window
        // Shift-Tab arrives as the backtab character.
        let character = shift ? "\u{19}" : "\t"
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: shift ? [.control, .shift] : .control, timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: 48))
        #expect(window.performKeyEquivalent(with: event))
    }

    func send(_ type: NSEvent.EventType, keyCode: UInt16, flags: NSEvent.ModifierFlags = []) {
        context.window.sendEvent(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: context.window.windowNumber, context: nil, characters: type == .keyDown ? "\u{1b}" : "",
            charactersIgnoringModifiers: type == .keyDown ? "\u{1b}" : "", isARepeat: false, keyCode: keyCode)!)
    }
    func releaseControl() { send(.flagsChanged, keyCode: 59) }
}

// @lat: [[lat.md/tests/session-tests#Recent tab switching]]
@Test @MainActor func recentTabSwitching() throws {
    let fixture = try RecentTabFixture()
    defer { fixture.tearDown() }
    let store = fixture.store
    let (a, b, c, d) = (fixture.ids[0], fixture.ids[1], fixture.ids[2], fixture.ids[3])
    #expect(Array(store.recentTabs.prefix(4)) == [d, c, b, a])

    // A single press and release returns to the previously used tab.
    try fixture.press()
    #expect(store.selectedTab.id == d)
    #expect(store.tabCycle?.target == c)
    fixture.releaseControl()
    #expect(store.tabCycle == nil)
    #expect(store.selectedTab.id == c)
    #expect(Array(store.recentTabs.prefix(2)) == [c, d])
    try fixture.press(); fixture.releaseControl()
    #expect(store.selectedTab.id == d)

    // Holding Control walks deeper into the frozen order; Shift walks back; both wrap.
    try fixture.press(); try fixture.press()
    #expect(store.tabCycle?.target == b)
    try fixture.press(shift: true)
    #expect(store.tabCycle?.target == c)
    try fixture.press(); try fixture.press(); try fixture.press()
    #expect(store.tabCycle?.target == d)
    try fixture.press(shift: true)
    #expect(store.tabCycle?.target == a)
    #expect(store.selectedTab.id == d)
    fixture.releaseControl()
    #expect(store.selectedTab.id == a)
    #expect(Array(store.recentTabs.prefix(4)) == [a, d, c, b])

    // Control-Tab from the location popup closes it and cycles.
    fixture.context.window.orderFront(nil)
    fixture.context.addressPanel.show(for: store.selectedTab.focusedPane)
    let popup = try #require(NSApp.windows.first { fixture.context.addressPanel.owns($0) })
    #expect(popup.isVisible)
    try fixture.press(in: popup)
    #expect(!popup.isVisible)
    #expect(store.tabCycle?.target == d)
    fixture.send(.keyDown, keyCode: 53, flags: .control)

    // Escape cancels without switching.
    try fixture.press()
    fixture.send(.keyDown, keyCode: 53, flags: .control)
    #expect(store.tabCycle == nil)
    #expect(store.selectedTab.id == a)

    // Closed tabs leave both the recent order and an in-progress cycle.
    try fixture.press()
    #expect(store.tabCycle?.target == d)
    store.closeTab(d)
    #expect(!store.recentTabs.contains(d))
    #expect(store.tabCycle?.order == [a, c, b])
    #expect(store.tabCycle?.target == c)
    fixture.releaseControl()
    #expect(store.selectedTab.id == c)
}

// @lat: [[lat.md/tests/session-tests#Tab switcher popup]]
@Test @MainActor func tabSwitcherPopup() async throws {
    let fixture = try RecentTabFixture()
    defer { fixture.tearDown() }
    let store = fixture.store, switcher = fixture.context.tabSwitcher!
    let (a, b, c, d) = (fixture.ids[0], fixture.ids[1], fixture.ids[2], fixture.ids[3])

    // A quick tap commits before the popup appears.
    try fixture.press(); fixture.releaseControl()
    try await Task.sleep(for: .seconds(TabSwitcherPanel.presentationDelay * 2))
    #expect(!switcher.isVisible)

    // Holding Control shows recent tabs in order with the target highlighted.
    try fixture.press(); try fixture.press()
    try await Task.sleep(for: .seconds(TabSwitcherPanel.presentationDelay * 2))
    #expect(switcher.isVisible)
    #expect(switcher.rowTabIDs == [c, d, b, a])
    #expect(switcher.highlightedRow == 2)
    try fixture.press(shift: true)
    #expect(switcher.highlightedRow == 1)

    // Control-clicking a row selects it and dismisses the popup.
    let rect = switcher.table.rect(ofRow: 3)
    let location = switcher.table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
    let switcherWindow = try #require(switcher.table.window)
    let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: .control,
        timestamp: 0, windowNumber: switcherWindow.windowNumber, context: nil,
        eventNumber: 0, clickCount: 1, pressure: 1))
    switcher.table.mouseDown(with: click)
    #expect(store.selectedTab.id == a)
    #expect(store.tabCycle == nil)
    #expect(!switcher.isVisible)

    // Losing key status cancels a held cycle and hides the popup.
    try fixture.press()
    switcher.present()
    #expect(switcher.isVisible)
    fixture.context.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: fixture.context.window))
    #expect(store.tabCycle == nil)
    #expect(!switcher.isVisible)
    #expect(store.selectedTab.id == a)
}

// @lat: [[lat.md/tests/session-tests#Tab switcher matches the location popup]]
@Test @MainActor func tabSwitcherMatchesLocationPopup() throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendSwitcherPlacement-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    let tabs = (1...3).map { BrowserTab(title: "Tab \($0)", pages: [Page(address: "about:blank")]) }
    store.session.workspaces = [Workspace(name: "Test", tabs: tabs)]
    for tab in tabs { store.select(tab.id) }
    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1200, height: 800),
        styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
    window.contentView = content
    // A pane beside a sidebar: popups center on the pane, not the whole window.
    let pane = PaneDropHost(frame: NSRect(x: 300, y: 20, width: 880, height: 760))
    pane.store = store; pane.tabID = store.selectedTab.id; pane.pageID = store.selectedTab.focusedPane
    content.addSubview(pane)
    window.orderFront(nil)
    let address = AddressPanelController(store: store, parentWindow: window)
    let switcher = TabSwitcherPanel(store: store, parentWindow: window)
    defer { address.dismiss(restoreFocus: false); store.cancelTabCycle(); switcher.dismiss(); window.close() }

    address.show(for: store.selectedTab.focusedPane)
    let addressFrame = try #require(window.childWindows?.first { address.owns($0) }).frame
    address.dismiss(restoreFocus: false)
    store.cycleRecentTabs()
    switcher.update()
    switcher.present()
    let switcherFrame = try #require(window.childWindows?.first { switcher.owns($0) }).frame
    let paneFrame = window.convertToScreen(pane.convert(pane.visibleRect, to: nil))
    #expect(abs(switcherFrame.midX - paneFrame.midX) <= 1)
    #expect(switcherFrame.midX == addressFrame.midX)
    #expect(switcherFrame.maxY == addressFrame.maxY)
    #expect(switcherFrame.width == addressFrame.width)
    #expect(switcherFrame.height == 3 * PopupLayout.rowHeight + 2 * PopupLayout.inset)
}

/// Stands in for focused web content, which claims key equivalents for the page.
private final class KeyEquivalentClaimingView: NSView {
    var claimed = 0
    override var acceptsFirstResponder: Bool { true }
    override func performKeyEquivalent(with event: NSEvent) -> Bool { claimed += 1; return true }
}

// @lat: [[lat.md/tests/session-tests#Recent tab shortcuts from focused content]]
@Test @MainActor func recentTabShortcutsFromFocusedContent() throws {
    let fixture = try RecentTabFixture()
    defer { fixture.tearDown() }
    let store = fixture.store, window = fixture.context.window
    let (c, d) = (fixture.ids[2], fixture.ids[3])
    let content = try #require(window.contentView)
    let claiming = KeyEquivalentClaimingView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
    content.addSubview(claiming)
    defer { claiming.removeFromSuperview() }
    #expect(window.makeFirstResponder(claiming))
    // AppKit offers a key window's views key equivalents before the main menu;
    // focused content must not swallow tab switching.
    for shift in [false, true] {
        let character = shift ? "\u{19}" : "\t"
        #expect(window.performKeyEquivalent(with: try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: shift ? [.control, .shift] : .control, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: 48))))
        if !shift { #expect(store.tabCycle?.target == c) }
    }
    #expect(claiming.claimed == 0)
    #expect(store.tabCycle?.target == d)
    fixture.releaseControl()
    #expect(store.selectedTab.id == d)
    // Other key equivalents still reach focused content first.
    #expect(window.performKeyEquivalent(with: try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "k",
        charactersIgnoringModifiers: "k", isARepeat: false, keyCode: 40))))
    #expect(claiming.claimed == 1)
}
