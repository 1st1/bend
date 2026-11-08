import AppKit
import Combine
import Testing
import WebKit
import BrowseCore
@testable import Browse

// @lat: [[tests#Settings section toolbar]]
@Test @MainActor func settingsSectionToolbar() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendSettingsToolbar-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    let settings = SettingsWindowController(store: store)
    settings.window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    let initialScreen = try #require(NSScreen.main)
    settings.show(centeredOn: initialScreen)
    defer { settings.window.close() }
    try await Task.sleep(for: .milliseconds(300))
    #expect(abs(settings.window.frame.midX - initialScreen.visibleFrame.midX) <= 1)
    #expect(abs(settings.window.frame.midY - initialScreen.visibleFrame.midY) <= 1)
    for screen in NSScreen.screens {
        settings.window.orderOut(nil)
        settings.window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        settings.show(centeredOn: screen)
        try await Task.sleep(for: .milliseconds(100))
        #expect(abs(settings.window.frame.midX - screen.visibleFrame.midX) <= 1)
        #expect(abs(settings.window.frame.midY - screen.visibleFrame.midY) <= 1)
    }
    settings.window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    func table(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { table(in: $0) }.first
    }
    let content = try #require(settings.window.contentView)
    let sidebar = try #require(table(in: content))
    for (index, title) in ["UI", "Websites", "Extensions", "Development"].enumerated() {
        sidebar.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        try await Task.sleep(for: .milliseconds(200))
        #expect(settings.window.title == title)
        #expect(abs(sidebar.enclosingScrollView!.frame.width - 200) < 1)
        var ancestor = sidebar.superview
        while ancestor != nil, !(ancestor is NSSplitView) { ancestor = ancestor?.superview }
        let split = try #require(ancestor as? NSSplitView)
        let nativeSidebar = try #require((split.delegate as? NSSplitViewController)?.splitViewItems.first)
        #expect(nativeSidebar.minimumThickness == 200)
        #expect(nativeSidebar.maximumThickness == 200)
        #expect(!nativeSidebar.canCollapse)
        for position: CGFloat in [150, 260] {
            split.setPosition(position, ofDividerAt: 0)
            try await Task.sleep(for: .milliseconds(100))
            content.layoutSubtreeIfNeeded()
            #expect(abs(split.arrangedSubviews[0].frame.width - 200) < 1)
        }
        #expect(settings.window.titlebarAppearsTransparent)
        #expect(settings.window.minSize.width == 880)
        #expect(settings.window.maxSize.width == settings.window.minSize.width)
        #expect(settings.window.maxSize.height > settings.window.minSize.height)
        let toolbar = try #require(settings.window.toolbar)
        let titleItem = try #require(toolbar.items.first { $0.itemIdentifier.rawValue.contains("settings.sectionTitle") })
        let titleView = try #require(titleItem.view)
        let titleFrame = titleView.convert(titleView.bounds, to: nil)
        #expect(titleFrame.minX >= sidebar.convert(sidebar.bounds, to: nil).maxX)
        func scrollViews(in view: NSView) -> [NSScrollView] {
            if let scroll = view as? NSScrollView { return [scroll] }
            return view.subviews.flatMap { scrollViews(in: $0) }
        }
        let detail = try #require(scrollViews(in: content).first { $0 !== sidebar.enclosingScrollView })
        #expect(detail.contentInsets.top > 0)
        let originalOrigin = detail.contentView.bounds.origin
        if let document = detail.documentView, document.bounds.height > detail.contentView.bounds.height {
            detail.contentView.scroll(to: NSPoint(x: originalOrigin.x, y: originalOrigin.y + 100))
            detail.reflectScrolledClipView(detail.contentView)
            try await Task.sleep(for: .milliseconds(200))
            #expect(detail.contentView.bounds.origin.y > originalOrigin.y)
            #expect(!settings.window.titlebarAppearsTransparent)
            #expect(titleView.convert(titleView.bounds, to: nil) == titleFrame)
            detail.contentView.scroll(to: originalOrigin)
            detail.reflectScrolledClipView(detail.contentView)
            try await Task.sleep(for: .milliseconds(200))
            #expect(detail.contentView.bounds.origin == originalOrigin)
            #expect(settings.window.titlebarAppearsTransparent)
        }
    }
}

// @lat: [[tests#Settings close shortcut]]
@Test @MainActor func settingsCloseShortcut() throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendSettingsClose-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let owner = BrowserWindows(root: root, persistentExtensions: false)
    owner.restore(show: false)
    let browser = try #require(owner.active)
    browser.store.split(.horizontal)
    browser.addressPanel.dismiss(restoreFocus: false)
    let original = browser.store.selectedTab
    browser.window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    browser.window.makeKeyAndOrderFront(nil)
    let delegate = AppDelegate(browserWindows: owner)
    let previousMenu = NSApp.mainMenu
    delegate.installMenus()
    let settings = SettingsWindowController(store: owner.sharedStore)
    defer {
        settings.window.close()
        NSApp.mainMenu = previousMenu
        owner.prepareToQuit()
        for context in owner.windows { context.window.close() }
    }
    settings.window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    settings.show()
    #expect(settings.window.styleMask.contains(.fullSizeContentView))
    #expect(settings.window.titleVisibility == .hidden)
    #expect(settings.window.titlebarAppearsTransparent)
    func closeShortcut() throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: NSApp.keyWindow?.windowNumber ?? 0,
            context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
        #expect(try #require(NSApp.mainMenu).performKeyEquivalent(with: event))
    }
    // Supply the focused native window directly: an offscreen NSWindow cannot
    // become key in the headless runner. The menu action uses this same route.
    delegate.closeFocusedWindow(settings.window)
    #expect(!settings.window.isVisible)
    #expect(browser.store.selectedTab.pages.map(\.id) == original.pages.map(\.id))
    #expect(browser.store.selectedTab.focusedPane == original.focusedPane)
    #expect(!browser.store.canReopenClosed)
    browser.window.makeKeyAndOrderFront(nil)
    delegate.closeFocusedWindow(browser.window)
    #expect(browser.store.selectedTab.pages.count == original.pages.count - 1)
    browser.store.newTab()
    #expect(browser.addressPanel.owns(try #require(NSApp.keyWindow)))
    try closeShortcut()
    #expect(NSApp.keyWindow.map { browser.addressPanel.owns($0) } != true)
    #expect(browser.store.session.workspaces.flatMap(\.tabs).count == 1)
}

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
    #expect(first.store.downloads === second.store.downloads)
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
    second.store.paneHighlight.style = .outline
    second.store.paneHighlight.outlineWidth = 4
    #expect(first.store.paneHighlight.style == .outline)
    #expect(first.store.paneHighlight.outlineWidth == 4)
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

// @lat: [[tests#Closing the last browser pane]]
@Test @MainActor func closingLastBrowserPane() throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendLastPane-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let owner = BrowserWindows(root: root, persistentExtensions: false)
    owner.restore(show: false)
    let first = try #require(owner.active)
    let other = owner.newWindow(show: false)
    let otherTab = other.store.selectedTab
    let delegate = AppDelegate(browserWindows: owner)
    defer { owner.prepareToQuit(); for context in owner.windows { context.window.close() } }
    // Offscreen windows cannot reliably become key in the runner.
    first.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: first.window))
    let tab = BrowserTab(pages: [Page(), Page()])
    first.store.session.workspaces = [Workspace(name: "Tabs", tabs: [tab])]
    first.store.session.selectedTab = tab.id
    delegate.closeFocusedWindow(first.window)
    #expect(owner.windows.count == 2)
    #expect(first.store.selectedTab.pages.count == 1)
    let originalTabID = first.store.selectedTab.id
    first.store.newTab(address: "browse://guide")
    delegate.closeFocusedWindow(first.window)
    #expect(owner.windows.count == 2)
    #expect(first.store.selectedTab.id == originalTabID)
    #expect(first.store.session.workspaces.flatMap(\.tabs).count == 1)
    delegate.closeFocusedWindow(first.window)
    #expect(owner.windows.count == 1)
    #expect(owner.active === other)
    #expect(other.store.selectedTab.id == otherTab.id)
    #expect(other.store.selectedTab.pages.map(\.id) == otherTab.pages.map(\.id))
    // The only remaining browser stays open and focuses a fresh address entry.
    other.window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    other.window.makeKeyAndOrderFront(nil)
    let closedPage = other.store.selectedTab.pages[0]
    other.store.controller(for: closedPage).navigate("https://example.com/")
    delegate.closeFocusedWindow(other.window)
    #expect(owner.windows.count == 1)
    #expect(other.window.isVisible)
    #expect(other.store.selectedTab.pages.count == 1)
    #expect(other.store.selectedTab.pages[0].address == "browse://start")
    #expect(other.store.selectedTab.pages[0].id != closedPage.id)
    #expect(other.store.existingController(for: closedPage.id) == nil)
    #expect(other.store.canReopenClosed)
    let popup = try #require(other.window.childWindows?.first { other.addressPanel.owns($0) })
    #expect(popup.isVisible)
    #expect(popup.firstResponder is NSTextView)
    delegate.closeFocusedWindow(popup)
    #expect(owner.windows.count == 1)
    #expect(other.store.selectedTab.pages.count == 1)
    #expect(other.store.selectedTab.pages[0].address == "browse://start")
    #expect(popup.isVisible)
    // Explicitly closing the native window still closes it.
    other.window.close()
    #expect(owner.windows.isEmpty)
    // With no browser left, another close command must not mutate the retained store.
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let snapshot = try encoder.encode(owner.sharedStore.session)
    delegate.closeFocusedWindow(nil)
    #expect(try encoder.encode(owner.sharedStore.session) == snapshot)
}

// @lat: [[tests#Window control alignment]]
@Test @MainActor func windowControlAlignment() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendChromeAlignment-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let owner = BrowserWindows(root: root, persistentExtensions: false)
    owner.restore(show: false)
    let context = try #require(owner.active)
    defer { owner.prepareToQuit(); context.window.close() }
    context.window.makeKeyAndOrderFront(nil)
    context.window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    func descendants<T: NSView>(_ type: T.Type, _ view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, $0) }
    }
    var originalButtons: [NSRect]?
    for width: CGFloat in [1400, 900] {
        context.window.setContentSize(NSSize(width: width, height: 850))
        for sidebar in [true, false, true] {
            context.store.sidebarVisible = sidebar
            for _ in 0..<6 {
                context.window.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(50))
            }
            let buttons = try [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].map { type in
                let button = try #require(context.window.standardWindowButton(type))
                let frame = button.convert(button.bounds, to: nil)
                return NSRect(x: frame.minX, y: context.window.frame.height - frame.maxY,
                              width: frame.width, height: frame.height)
            }
            if let originalButtons { #expect(buttons == originalButtons) }
            else { originalButtons = buttons }
            let headers = descendants(PaneDragSourceView.self, context.window.contentView!).filter {
                $0.onHover != nil && !$0.isHiddenOrHasHiddenAncestor
            }
            #expect(headers.count == 2)
            for header in headers {
                let frame = header.convert(header.bounds, to: nil)
                let centerFromTop = context.window.frame.height - frame.midY
                #expect(abs(centerFromTop - buttons[0].midY) <= 0.5)
            }

        }
    }
}

// @lat: [[tests#Fullscreen chrome transitions]]
@Test(.enabled(if: ProcessInfo.processInfo.environment["BEND_FULLSCREEN_TEST"] == "1"))
@MainActor func fullscreenChromeTransitions() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendFullscreen-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let owner = BrowserWindows(root: root, persistentExtensions: false)
    owner.restore(show: false)
    let context = try #require(owner.active)
    let originalPolicy = NSApp.activationPolicy()
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    context.window.makeKeyAndOrderFront(nil)
    defer { owner.prepareToQuit(); context.window.close(); NSApp.setActivationPolicy(originalPolicy) }
    let page = context.store.selectedTab.pages[0]
    let controller = context.store.controller(for: page)
    let web = controller.webView
    controller.isStartPage = false
    web.loadHTMLString("<input value='draft'><script>window.token='retained'</script>", baseURL: nil)
    for _ in 0..<50 {
        if (try? await web.evaluateJavaScript("window.token")) as? String == "retained" { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    func settle() async throws {
        for _ in 0..<5 {
            context.window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    func titleHandle(in view: NSView) -> PaneDragSourceView? {
        if let handle = view as? PaneDragSourceView, handle.pageID == page.id, handle.onHover != nil { return handle }
        return view.subviews.lazy.compactMap { titleHandle(in: $0) }.first
    }
    func titleFrame() throws -> NSRect {
        let header = try #require(titleHandle(in: context.window.contentView!))
        let frame = header.convert(header.bounds, to: nil)
        let root = try #require(context.window.contentView?.superview)
        #expect(root.hitTest(root.convert(NSPoint(x: frame.midX, y: frame.midY), from: nil)) === header)
        return frame
    }
    context.store.sidebarVisible = false
    try await settle()
    let originalTitle = try titleFrame()
    let toolbar = context.window.toolbar
    let closeButton = try #require(context.window.standardWindowButton(.closeButton))
    let originalButtonSize = closeButton.frame.size
    let originalButtonTop = context.window.frame.height - closeButton.convert(closeButton.bounds, to: nil).midY
    context.store.requestAddress()
    context.window.toggleFullScreen(nil)
    for _ in 0..<100 {
        try await Task.sleep(for: .milliseconds(100))
        if context.store.isFullScreen { break }
    }
    try #require(context.store.isFullScreen)
    try await settle()
    #expect(NSApp.presentationOptions.contains(.autoHideToolbar))
    // AppKit hosts the rollover titlebar in a separate window, even while hidden.
    let titlebarWindow = try #require(closeButton.window)
    #expect(titlebarWindow !== context.window)
    #expect(titlebarWindow.frame.height <= 32)
    // Hiding slides the native container; measure alignment inside that container.
    let buttonContainer = try #require(closeButton.superview)
    #expect(abs(closeButton.frame.midY - buttonContainer.bounds.midY) <= 0.5)
    #expect(context.window.toolbar?.isVisible == false)
    #expect(context.window.contentLayoutRect.maxY == context.window.contentView!.convert(context.window.contentView!.bounds, to: nil).maxY)
    #expect(context.window.childWindows?.contains { context.addressPanel.owns($0) && $0.isVisible } != true)
    // Hidden window controls leave no dead space in the pane title row.
    #expect(try titleFrame().minX < originalTitle.minX)
    context.store.sidebarVisible = true
    try await settle()
    _ = try titleFrame()
    context.store.sidebarVisible = false
    try await settle()
    #expect(try titleFrame().minX < originalTitle.minX)
    #expect(context.store.existingController(for: page.id) === controller)
    #expect(try await web.evaluateJavaScript("window.token") as? String == "retained")
    context.window.toggleFullScreen(nil)
    for _ in 0..<100 {
        try await Task.sleep(for: .milliseconds(100))
        if !context.store.isFullScreen { break }
    }
    try #require(!context.store.isFullScreen)
    try await settle()
    #expect(!context.window.styleMask.contains(.fullScreen))
    #expect(context.window.toolbar === toolbar)
    #expect(context.window.toolbar?.isVisible == true)
    #expect(closeButton.frame.size == originalButtonSize)
    #expect(abs(context.window.frame.height - closeButton.convert(closeButton.bounds, to: nil).midY - originalButtonTop) <= 0.5)
    #expect(abs(try titleFrame().minX - originalTitle.minX) <= 0.5)
    #expect(context.store.existingController(for: page.id)?.webView === web)
    #expect(try await web.evaluateJavaScript("document.querySelector('input').value") as? String == "draft")
}
