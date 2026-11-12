import Foundation
import AppKit
import SwiftUI
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
    var legacyJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
    legacyJSON["paneBorders"] = ["separator": ["enabled": true, "color": ["red": 1, "green": 0, "blue": 0], "opacity": 1, "width": 4]]
    try JSONSerialization.data(withJSONObject: legacyJSON).write(to: file)
    let store = BrowserStore(sessionFile: file, persistentExtensions: false)
    #expect(store.selectedTab.id == legacy.selectedTab)
    #expect(store.commandClickDestination == .newPane)
    #expect(store.inactivePaneDimAmount == 0.08)
    #expect(store.windowGlass == .windowDefault)
    #expect(store.paneHeaderGlass == .headerDefault)
    #expect(store.paneHeaderTopRimClipping == BrowserStore.defaultHeaderTopRimClipping)
    #expect(store.paneHighlight == PaneHighlight())
    #expect(store.paneHighlight.style == .none)
    store.commandClickDestination = .newTab
    store.inactivePaneDimAmount = 0.35
    store.windowGlass = GlassAppearance(clear: true, tint: .init(red: 0.2, green: 0.4, blue: 0.8), darkening: 0.15)
    store.paneHeaderGlass = GlassAppearance(tint: .init(red: 0.8, green: 0.3, blue: 0.1), darkening: 0.65,
                                           solidColor: .init(red: 0.2, green: 0.3, blue: 0.4))
    #expect(store.paneHeaderTopRimClipping == 0.5)
    #expect(store.paneHeaderBottomRimClipping == 1.1)
    store.paneHeaderTopRimClipping = 2.5
    store.paneHeaderBottomRimClipping = 1.25
    var highlight = PaneHighlight()
    highlight.style = .titleTint
    highlight.outlineColor = .init(red: 0.7, green: 0.3, blue: 0.1)
    highlight.outlineWidth = 1.5
    highlight.outlineGap = 1.25
    highlight.glowColor = .init(red: 0.2, green: 0.8, blue: 0.5)
    highlight.glowIntensity = 0.75
    highlight.glowSpread = 16
    highlight.titleTintColor = .init(red: 0.8, green: 0.3, blue: 0.6)
    highlight.titleTintIntensity = 0.42
    store.paneHighlight = highlight
    store.save()
    #expect(store.persistenceError == nil)
    let restored = BrowserStore(sessionFile: file, persistentExtensions: false)
    #expect(restored.commandClickDestination == .newTab)
    #expect(restored.inactivePaneDimAmount == 0.35)
    #expect(restored.windowGlass == store.windowGlass)
    #expect(restored.paneHeaderGlass == store.paneHeaderGlass)
    #expect(restored.paneHeaderTopRimClipping == 2.5)
    #expect(restored.paneHeaderBottomRimClipping == 1.25)
    let secondary = BrowserStore(sessionFile: directory.appendingPathComponent("secondary.json"),
                                 persistentExtensions: false, sharedStore: store)
    #expect(secondary.paneHeaderTopRimClipping == 2.5)
    secondary.paneHeaderTopRimClipping = 4
    #expect(store.paneHeaderTopRimClipping == 4)
    store.paneHeaderTopRimClipping = -1
    #expect(store.paneHeaderTopRimClipping == 0)
    store.paneHeaderTopRimClipping = 100
    #expect(store.paneHeaderTopRimClipping == 16)
    store.paneHeaderTopRimClipping = .nan
    #expect(store.paneHeaderTopRimClipping == 16)
    store.session.paneHeaderTopRimClipping = .infinity
    #expect(store.paneHeaderTopRimClipping == BrowserStore.defaultHeaderTopRimClipping)
    store.paneHeaderTopRimClipping = BrowserStore.defaultHeaderTopRimClipping
    #expect(secondary.paneHeaderBottomRimClipping == 1.25)
    secondary.paneHeaderBottomRimClipping = 4
    #expect(store.paneHeaderBottomRimClipping == 4)
    store.paneHeaderBottomRimClipping = -1
    #expect(store.paneHeaderBottomRimClipping == 0)
    store.paneHeaderBottomRimClipping = 100
    #expect(store.paneHeaderBottomRimClipping == 16)
    store.paneHeaderBottomRimClipping = .nan
    #expect(store.paneHeaderBottomRimClipping == 16)
    store.session.paneHeaderBottomRimClipping = .infinity
    #expect(store.paneHeaderBottomRimClipping == BrowserStore.defaultHeaderBottomRimClipping)
    store.paneHeaderBottomRimClipping = BrowserStore.defaultHeaderBottomRimClipping
    #expect(restored.paneHighlight == highlight)
    highlight.style = .none
    store.paneHighlight = highlight
    store.save()
    let unhighlighted = BrowserStore(sessionFile: file, persistentExtensions: false)
    #expect(unhighlighted.paneHighlight == highlight)
    var oldHighlight = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(highlight)) as? [String: Any])
    oldHighlight["style"] = "glow"
    oldHighlight.removeValue(forKey: "titleTintColor")
    oldHighlight.removeValue(forKey: "titleTintIntensity")
    oldHighlight.removeValue(forKey: "glowSpread")
    oldHighlight.removeValue(forKey: "outlineGap")
    let migrated = try JSONDecoder().decode(PaneHighlight.self, from: JSONSerialization.data(withJSONObject: oldHighlight))
    #expect(migrated.style == .glow && migrated.glowIntensity == 0.75)
    #expect(migrated.glowSpread == 8)
    #expect(migrated.outlineGap == PaneHighlight().outlineGap)
    #expect(migrated.titleTintColor == PaneHighlight().titleTintColor)
    #expect(migrated.titleTintIntensity == PaneHighlight().titleTintIntensity)
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
    highlight.style = .outline
    highlight.outlineWidth = .infinity
    highlight.outlineGap = .nan
    highlight.glowIntensity = -1
    highlight.glowSpread = 100
    highlight.titleTintIntensity = 2
    highlight.titleTintColor = .init(red: -1, green: 0.5, blue: 2)
    highlight.outlineColor = .init(red: .nan, green: 0, blue: 0)
    highlight.glowColor = .init(red: 2, green: -1, blue: 0.5)
    store.paneHighlight = highlight
    #expect(store.paneHighlight.style == .outline)
    #expect(store.paneHighlight.outlineWidth == PaneHighlight().outlineWidth)
    #expect(store.paneHighlight.outlineGap == PaneHighlight().outlineGap)
    #expect(store.paneHighlight.glowIntensity == 0)
    #expect(store.paneHighlight.glowSpread == 24)
    #expect(store.paneHighlight.titleTintIntensity == 1)
    #expect(store.paneHighlight.titleTintColor == .init(red: 0, green: 0.5, blue: 1))
    #expect(store.paneHighlight.outlineColor == PaneHighlight().outlineColor)
    #expect(store.paneHighlight.glowColor == .init(red: 1, green: 0, blue: 0.5))
    highlight.outlineWidth = 50
    highlight.outlineGap = 50
    highlight.glowIntensity = .nan
    highlight.glowSpread = .infinity
    highlight.titleTintIntensity = .nan
    highlight.titleTintColor = .init(red: .infinity, green: 0, blue: 0)
    store.paneHighlight = highlight
    #expect(store.paneHighlight.outlineWidth == 2)
    #expect(store.paneHighlight.outlineGap == 2.5)
    #expect(store.paneHighlight.glowIntensity == PaneHighlight().glowIntensity)
    #expect(store.paneHighlight.glowSpread == PaneHighlight().glowSpread)
    #expect(store.paneHighlight.titleTintIntensity == PaneHighlight().titleTintIntensity)
    #expect(store.paneHighlight.titleTintColor == PaneHighlight().titleTintColor)
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
    let cancelled = store.cancelInitialAddressEntry(for: blank)
    #expect(cancelled)
    #expect(store.selectedTab.id == original.id && store.selectedTab.layout == original.layout)
    #expect(store.zoomedPane == original.focusedPane)
    #expect(store.session.workspaces[0].tabs.count == 1)
    #expect(!store.canReopenClosed)
    store.save()
    let restored = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    #expect(restored.session.selectedTab == original.id && restored.session.workspaces[0].tabs.count == 1)
    // Cancel either split direction from a non-first pane, restoring its zoom.
    let sourceID = original.pages.last!.id
    let sourceController = store.controller(for: original.pages.last!)
    for axis in [SplitAxis.horizontal, .vertical] {
        store.focus(sourceID)
        if store.zoomedPane != sourceID { store.toggleZoom(sourceID) }
        let before = store.selectedTab
        store.split(axis)
        let provisional = store.selectedTab.focusedPane
        _ = store.controller(for: store.selectedTab.pages.last!)
        #expect(store.zoomedPane == nil)
        #expect(store.cancelInitialAddressEntry(for: provisional))
        #expect(store.selectedTab.layout == before.layout)
        #expect(store.selectedTab.focusedPane == sourceID && store.zoomedPane == sourceID)
        #expect(store.selectedTab.pages.map(\.id) == before.pages.map(\.id))
        #expect(store.existingController(for: provisional) == nil)
        #expect(store.existingController(for: sourceID) === sourceController)
        #expect(!store.canReopenClosed)
        store.save()
        let reloaded = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
        #expect(reloaded.selectedTab.layout == before.layout)
    }
    // Existing tabs, completed entry, and panes added to a new tab are never discarded.
    #expect(!store.cancelInitialAddressEntry(for: original.focusedPane))
    store.newTab()
    let kept = store.selectedTab.focusedPane
    store.finishInitialAddressEntry(for: kept)
    #expect(!store.cancelInitialAddressEntry(for: kept))
    store.newTab()
    let split = store.selectedTab.focusedPane
    store.split(.horizontal)
    #expect(!store.cancelInitialAddressEntry(for: split))
    #expect(store.selectedTab.pages.count == 2)
    let newPane = store.selectedTab.focusedPane
    store.controller(for: store.selectedTab.pages.last!).navigate("browse://guide")
    #expect(!store.cancelInitialAddressEntry(for: newPane))
    store.newTab(address: "https://example.com")
    #expect(!store.cancelInitialAddressEntry(for: store.selectedTab.focusedPane))
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
        #expect(color == NSColor.placeholderTextColor)
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
    let beforeSplit = store.selectedTab
    for below in [false, true] {
        for useEscape in [true, false] {
            let splitKey = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: below ? [.command, .shift] : [.command],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: context.window.windowNumber,
                context: nil, characters: "d", charactersIgnoringModifiers: "d", isARepeat: false, keyCode: 2))
            #expect(try #require(NSApp.mainMenu).performKeyEquivalent(with: splitKey))
            #expect(store.selectedTab.pages.count == beforeSplit.pages.count + 1)
            let panel = try popup()
            let content = try #require(panel.contentView)
            let input = try #require(fields(content).first { $0.isEditable })
            input.stringValue = "changed my mind"
            if useEscape { try escape(panel) } else { try command("Close Pane") }
            #expect(!panel.isVisible)
            #expect(store.selectedTab.layout == beforeSplit.layout)
            #expect(store.selectedTab.focusedPane == beforeSplit.focusedPane)
            #expect(!store.canReopenClosed)
        }
    }
    // Escape in an existing tab only dismisses location entry.
    try command("Open Location…")
    try escape(try popup())
    #expect(store.session.selectedTab == original && store.session.workspaces[0].tabs.count == 1)
    // Outside dismissal also commits a split pane.
    store.split(.horizontal)
    let keptPane = store.selectedTab.focusedPane
    context.addressPanel.dismiss(restoreFocus: true)
    store.requestAddress()
    try escape(try popup())
    #expect(store.selectedTab.pages.contains { $0.id == keptPane })
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

// @lat: [[tests#Pane-centered location popup]]
@Test @MainActor func paneCenteredLocationPopup() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendPanePopup-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    if store.selectedTab.pages.count < 2 { store.split(.horizontal) }
    let pages = store.selectedTab.pages
    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1200, height: 800),
        styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
    window.contentView = content
    let left = PaneDropHost(frame: NSRect(x: 200, y: 20, width: 440, height: 760))
    let right = PaneDropHost(frame: NSRect(x: 650, y: 20, width: 530, height: 760))
    for (pane, page) in zip([left, right], pages) {
        pane.store = store; pane.tabID = store.selectedTab.id; pane.pageID = page.id
        content.addSubview(pane)
    }
    window.orderFront(nil)
    let controller = AddressPanelController(store: store, parentWindow: window)
    defer { controller.dismiss(restoreFocus: false); window.close() }
    func verify(_ pane: NSView, fixedTop: CGFloat? = nil) throws {
        let popup = try #require(window.childWindows?.first { controller.owns($0) })
        let frame = window.convertToScreen(pane.convert(pane.visibleRect, to: nil))
        #expect(abs(popup.frame.midX - frame.midX) <= 1)
        let expectedTop = fixedTop ?? (frame.maxY - frame.height / 5).rounded()
        #expect(popup.frame.maxY == expectedTop)
        #expect(popup.frame.width <= frame.width - 32)
        #expect(popup.frame.height <= frame.height - 32)
        #expect(window.frame.contains(popup.frame))
    }
    controller.show(for: pages[0].id)
    try verify(left)
    controller.show(for: pages[1].id)
    try verify(right)
    let popup = try #require(window.childWindows?.first { controller.owns($0) })
    let fixedTop = popup.frame.maxY
    let emptyHeight = popup.frame.height
    // Result growth and shrinkage leave the top edge exactly unchanged.
    for index in 0..<8 {
        store.recordVisit(url: "https://example.com/\(index)", title: "Page \(index)")
    }
    try verify(right, fixedTop: fixedTop)
    #expect(popup.frame.height > emptyHeight)
    for index in 0..<8 { store.removeHistory(url: "https://example.com/\(index)") }
    try verify(right, fixedTop: fixedTop)
    #expect(popup.frame.height == emptyHeight)
    // Validation errors also grow downward without shifting the input.
    func fields(in view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { fields(in: $0) }
    }
    let popupContent = try #require(popup.contentView)
    let input = try #require(fields(in: popupContent).first { $0.isEditable })
    input.stringValue = ""
    let action = try #require(input.action)
    #expect(input.sendAction(action, to: input.target))
    try verify(right, fixedTop: fixedTop)
    #expect(popup.frame.height > emptyHeight)
    right.frame = NSRect(x: 650, y: 400, width: 530, height: 380)
    try verify(right, fixedTop: fixedTop)
    // Use the visible portion when part of a pane is outside the canvas viewport.
    right.frame = NSRect(x: 650, y: -200, width: 530, height: 760)
    try verify(right, fixedTop: fixedTop)
    // Reopening takes a fresh one-fifth anchor from the pane's current bounds.
    controller.dismiss(restoreFocus: false)
    controller.show(for: pages[1].id)
    try verify(right)
    // Delayed mounting must not move a popup that was already placed using fallback bounds.
    controller.dismiss(restoreFocus: false)
    right.removeFromSuperview()
    controller.show(for: pages[1].id)
    let fallbackTop = popup.frame.maxY
    content.addSubview(right)
    try await Task.sleep(for: .milliseconds(100))
    try verify(right, fixedTop: fallbackTop)
}

// @lat: [[tests#Solid header appearance]]
@Test @MainActor func solidHeaderAppearance() throws {
    for clear in [false, true] {
        let legacy = Data("{\"clear\":\(clear),\"darkening\":0.5}".utf8)
        let decoded = try JSONDecoder().decode(GlassAppearance.self, from: legacy)
        #expect(decoded.style == (clear ? .clear : .regular))
        #expect(decoded.solidColor == GlassAppearance.defaultSolidColor)
    }
    var appearance = GlassAppearance(darkening: 1, solidColor: .init(red: 0.2, green: 0.3, blue: 0.4))
    appearance.style = .clear
    appearance = try JSONDecoder().decode(GlassAppearance.self, from: JSONEncoder().encode(appearance))
    #expect(appearance.solidColor == .init(red: 0.2, green: 0.3, blue: 0.4))
    appearance.style = .solid
    #expect(GlassAppearance(solidColor: .init(red: -1, green: 2, blue: 0.5))
        .normalized(defaultDarkening: 0).solidColor == .init(red: 0, green: 1, blue: 0.5))
    #expect(GlassAppearance(solidColor: .init(red: .nan, green: 0, blue: 0))
        .normalized(defaultDarkening: 0).solidColor == GlassAppearance.defaultSolidColor)

    // Render both paths: glass clipping and darkening must not affect solid paint.
    let native = SolidHeaderBackground(frame: NSRect(x: 0, y: 0, width: 120, height: 36))
    native.color = appearance.solidColor
    let context = try #require(CGContext(data: nil, width: 120, height: 36, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    native.draw(native.bounds)
    NSGraphicsContext.restoreGraphicsState()
    let bitmap = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
    let renderer = ImageRenderer(content: PaneChromeBackground(topRimClipping: 16, bottomRimClipping: 16,
        appearance: appearance).frame(width: 120, height: 36))
    let swiftUI = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
    // colorAt returns raw bitmap channels labeled as calibrated RGB. These
    // images are already sRGB; converting that label would transform them twice.
    for image in [bitmap, swiftUI] {
        let top = try #require(image.colorAt(x: 60, y: 1))
        let bottom = try #require(image.colorAt(x: 60, y: 34))
        #expect(top.alphaComponent == 1 && bottom.alphaComponent == 1)
        #expect(top.redComponent > 0.2 && bottom.redComponent < 0.2)
        #expect(top.greenComponent > 0.3 && bottom.greenComponent < 0.3)
        #expect(top.blueComponent > 0.4 && bottom.blueComponent < 0.4)
        #expect(top.redComponent - bottom.redComponent < 0.06)
    }
    for y in [1, 18, 34] {
        let a = try #require(bitmap.colorAt(x: 60, y: y))
        let b = try #require(swiftUI.colorAt(x: 60, y: y))
        #expect(abs(a.redComponent - b.redComponent) < 0.015)
        #expect(abs(a.greenComponent - b.greenComponent) < 0.015)
        #expect(abs(a.blueComponent - b.blueComponent) < 0.015)
    }
}
