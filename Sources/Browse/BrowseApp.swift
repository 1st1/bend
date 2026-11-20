import AppKit
import SwiftUI
import BrowseCore

@main
@MainActor
enum BrowseApp {
    static func main() {
        if CommandLine.arguments.dropFirst().elementsEqual(["--print-build-profile"]) {
            let profile = AppProfile.current
            let fields = ["profile": profile.rawValue, "name": profile.name,
                "bundleIdentifier": Bundle.main.bundleIdentifier ?? "unbundled",
                "profileBundleIdentifier": profile.bundleIdentifier,
                "diagnosticsEnabled": String(profile.defaults.bool(forKey: InputDiagnostics.enabledPreferenceKey)),
                "supportDirectory": profile.supportDirectory.path,
                "websiteStorage": profile.websiteStorageIdentifier?.uuidString ?? "default",
                "extensionStorage": profile.extensionStorageIdentifier?.uuidString ?? "default"]
            if let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
               let output = String(data: data, encoding: .utf8) { print(output) }
            return
        }
        if CommandLine.arguments.dropFirst().elementsEqual(["--diagnose-web-capabilities"]) {
            WebCapabilityProbe.run()
            return
        }
        if CommandLine.arguments.dropFirst().elementsEqual(["--diagnose-1password"]) {
            OnePasswordConnectionProbe.run()
            return
        }
        let app = NSApplication.shared
        InputDiagnostics.applyPreferences()
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    let browserWindows: BrowserWindows
    private var store: BrowserStore { browserWindows.active?.store ?? browserWindows.sharedStore }
    private var window: NSWindow? { browserWindows.active?.window }
    private var addressPanel: AddressPanelController? { browserWindows.active?.addressPanel }
    private let focusedWindow: () -> NSWindow?

    init(browserWindows: BrowserWindows = BrowserWindows(), shortcuts: CommandShortcuts = CommandShortcuts(), focusedWindow: @escaping () -> NSWindow? = { NSApp.keyWindow }) {
        self.browserWindows = browserWindows
        self.shortcuts = shortcuts
        self.focusedWindow = focusedWindow
        super.init()
    }
    private var clickMonitor: Any?
    let shortcuts: CommandShortcuts
    private var settingsWindow: SettingsWindowController?
    private(set) var printOperation: NSPrintOperation?
    private var browserWindowsReady = false
    private var pendingExternalURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        InputDiagnostics.transition(.launch, .started)
        browserWindows.onSettings = { [weak self] section in self?.presentSettings(section: section) }
        restoreBrowserWindows()
        installMenus()
        showReleaseNotesIfUpdated()
        AppUpdater.shared.start()
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            if let window = event.window, window === self?.settingsWindow?.window { return event }
            InputDiagnostics.record(.application, event: event)
            defer { InputDiagnostics.record(.applicationReturned, event: event) }
            guard event.type == .leftMouseDown else { return event }
            if let content = event.window?.contentView {
                var hit = content.hitTest(content.convert(event.locationInWindow, from: nil))
                while let view = hit {
                    if let tools = view as? DeveloperToolsPanel {
                        tools.onFocus?()
                        break
                    }
                    if let browser = view as? FocusWebView {
                        InputDiagnostics.transition(.monitorFocus, .started, event: event, view: browser)
                        browser.onFocus?()
                        InputDiagnostics.transition(.monitorFocus, .finished, event: event, view: browser)
                        break
                    }
                    hit = view.superview
                }
            }
            return event
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        InputDiagnostics.transition(.launch, .finished, window: window)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        InputDiagnostics.transition(.appActivation, .started, window: window)
    }

    // @lat: [[lat.md/architecture/external-links#Default browser]]
    func application(_ application: NSApplication, open urls: [URL]) {
        pendingExternalURLs.append(contentsOf: urls.filter {
            (["http", "https"].contains($0.scheme?.lowercased() ?? "") && !($0.host ?? "").isEmpty)
                || LocalWebDocument.accepts($0)
        })
        openPendingExternalURLs()
    }

    func restoreBrowserWindows(show: Bool = true) {
        browserWindows.restore(show: show)
        browserWindowsReady = true
        openPendingExternalURLs(show: show)
    }

    private func openPendingExternalURLs(show: Bool = true) {
        guard browserWindowsReady, !pendingExternalURLs.isEmpty else { return }
        let context = browserWindows.active ?? browserWindows.newWindow(show: show)
        context.addressPanel.dismiss(restoreFocus: false)
        let urls = pendingExternalURLs
        pendingExternalURLs.removeAll()
        for url in urls { context.store.newTab(address: url.absoluteString) }
        if show {
            context.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    func applicationDidResignActive(_ notification: Notification) {
        InputDiagnostics.transition(.appActivation, .finished, window: window)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        InputDiagnostics.transition(.launch, .finished, window: window, flags: ["terminating": true])
        InputDiagnostics.flush()
        if #available(macOS 15.4, *) { store.extensions.diagnostics.record(.hostStopping) }
        browserWindows.prepareToQuit()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        browserWindows.prepareToQuit()
        if let load = browserWindows.sharedStore.historyLoad {
            Task {
                await load.value
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        return .terminateNow
    }

    func installMenus() {
        let main = NSMenu()
        let appMenu = NSMenu(title: AppProfile.current.name)
        appMenu.addItem(withTitle: "About \(AppProfile.current.name)", action: #selector(about), keyEquivalent: "").target = self
        if AppUpdater.shared.isEnabled {
            let update = appMenu.addItem(withTitle: "Check for Updates…",
                action: #selector(AppUpdater.checkForUpdates(_:)), keyEquivalent: "")
            update.target = AppUpdater.shared
        }
        add("What’s New", #selector(showChangelog), "", to: appMenu)
        appMenu.addItem(.separator())
        add("Settings…", #selector(showSettings), ",", to: appMenu)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(AppProfile.current.name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit \(AppProfile.current.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        append(appMenu, to: main)

        let file = NSMenu(title: "File")
        add("New Window", #selector(newWindow), "n", to: file)
        add("New Private Window", #selector(newPrivateWindow), "N", modifiers: [.command, .shift], to: file)
        add("New Tab", #selector(newTab), "t", to: file)
        add("Open Location…", #selector(openLocation), "l", to: file)
        file.addItem(.separator())
        add("Close Pane", #selector(closePane), "w", to: file)
        add("Close Tab", #selector(closeTab), "w", modifiers: [.command, .shift], to: file)
        add("Reopen Closed Pane or Tab", #selector(reopenClosed), "t", modifiers: [.command, .shift], to: file)
        file.addItem(.separator())
        add("Print…", #selector(printPage), "p", to: file)
        append(file, to: main)

        let edit = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        add("Copy Page URL", #selector(copyPageURL), "c", modifiers: [.command, .option], to: edit)
        edit.addItem(.separator())
        for (title, action, key, modifiers) in [
            ("Find in Page…", NSTextFinder.Action.showFindInterface, "f", NSEvent.ModifierFlags.command),
            ("Find Next", .nextMatch, "g", .command),
            ("Find Previous", .previousMatch, "g", [.command, .shift])
        ] {
            add(title, #selector(findInPage(_:)), key, modifiers: modifiers, to: edit)
            edit.items.last?.tag = Int(action.rawValue)
        }
        append(edit, to: main)

        let view = NSMenu(title: "View")
        add("Show Commands…", #selector(showCommands), "p", modifiers: [.command, .shift], to: view)
        add("Split Right", #selector(splitRight), "d", to: view)
        add("Split Below", #selector(splitBelow), "d", modifiers: [.command, .shift], to: view)
        add("Zoom Pane", #selector(zoomPane), "\r", modifiers: [.command, .shift], to: view)
        add("Show Chat", #selector(toggleChat), "c", modifiers: [.command, .shift], to: view)
        add("Toggle Sidebar", #selector(toggleSidebar), "s", modifiers: [.command, .shift], to: view)
        view.addItem(.separator())
        add("Reload Page", #selector(reload), "r", to: view)
        add("Back", #selector(back), "[", to: view)
        add("Forward", #selector(forward), "]", to: view)
        view.addItem(.separator())
        for (title, key, direction) in [("Zoom In", "+", 1), ("Zoom Out", "-", -1), ("Actual Size", "0", 0)] {
            add(title, #selector(zoomPage(_:)), key, to: view)
            view.items.last?.tag = direction
        }
        // Also accept Command-= without requiring Shift on a US keyboard.
        add("Zoom In", #selector(zoomPage(_:)), "=", to: view)
        view.items.last?.tag = 1
        view.items.last?.isHidden = true
        view.items.last?.allowsKeyEquivalentWhenHidden = true
        append(view, to: main)
        let history = NSMenu(title: "History")
        add("Show History", #selector(showHistory), "y", to: history)
        append(history, to: main)
        let develop = NSMenu(title: "Develop")
        add("Show Web Inspector", #selector(showWebInspector), "i", modifiers: [.command, .shift], to: develop)
        add("Show JavaScript Console", #selector(showJavaScriptConsole), "", to: develop)
        append(develop, to: main)
        let commands = NSMenu(title: "Commands")
        append(commands, to: view)
        shortcuts.install(commands: shortcutCommands(), menu: main, extraMenu: commands, target: self)
        NSApp.mainMenu = main
    }
    private func append(_ menu: NSMenu, to main: NSMenu) {
        let item = NSMenuItem(); item.title = menu.title; item.submenu = menu; main.addItem(item)
    }
    private func add(_ title: String, _ action: Selector, _ key: String, modifiers: NSEvent.ModifierFlags = .command, to menu: NSMenu) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
        item.target = self; item.keyEquivalentModifierMask = modifiers
    }
    private var focused: PageController {
        store.controller(for: store.selectedTab.pages.first { $0.id == store.selectedTab.focusedPane }!)
    }
    @objc func newWindow() { browserWindows.newWindow() }
    @objc func newPrivateWindow() { browserWindows.newPrivateWindow() }
    @objc func newTab() { store.newTab() }
    @objc private func showSettings() {
        presentSettings()
    }
    private func presentSettings(section: SettingsSection? = nil) {
        addressPanel?.dismiss(restoreFocus: false)
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(store: browserWindows.sharedStore, shortcuts: shortcuts) { [weak self] in
                self?.shortcutCommands() ?? []
            }
        }
        settingsWindow?.show(from: browserWindows.active?.window, section: section)
    }
    // @lat: [[lat.md/architecture/commands#Command popup]]
    private var commandSelection: (pane: UUID, revision: UUID, text: String)?
    private var commandSelectionRequest = UUID()
    @objc func showCommands() {
        guard let context = browserWindows.active else { return }
        let tabID = context.store.selectedTab.id
        let paneID = context.store.selectedTab.focusedPane
        commandSelection = nil
        let request = UUID()
        commandSelectionRequest = request
        if !context.store.isPrivate, let controller = context.store.existingController(for: paneID) {
            let revision = controller.aiNavigationRevision
            Task { [weak self, weak context] in
                let text = (try? await controller.selectedPageText()) ?? ""
                guard let self, let context, self.commandSelectionRequest == request,
                      context.store.selectedTab.id == tabID, context.store.selectedTab.focusedPane == paneID,
                      controller.aiNavigationRevision == revision else { return }
                self.commandSelection = (paneID, revision, text)
                context.addressPanel.refreshCommands()
            }
        }
        context.addressPanel.showCommands(for: paneID) { [weak self, weak context] in
            guard let self, let context, self.browserWindows.active === context,
                  context.store.selectedTab.id == tabID,
                  context.store.selectedTab.focusedPane == paneID else { return [] }
            return self.popupCommands()
        }
    }

    func shortcutCommands() -> [PopupCommand] {
        let palette = PopupCommand(id: "showCommands", title: "Open Command Palette", detail: "Show Commands",
            icon: "command", menuAction: #selector(showCommands)) { [weak self] in self?.showCommands() }
        return [palette] + popupCommands().filter { $0.id != "changelog" }
    }

    func popupCommands() -> [PopupCommand] {
        let store = store
        let tab = store.selectedTab
        let page = store.existingController(for: tab.focusedPane)
        let favorite = store.favorite(for: tab)
        let selection = commandSelection.flatMap { value -> String? in
            guard value.pane == tab.focusedPane,
                  store.existingController(for: value.pane)?.aiNavigationRevision == value.revision else { return nil }
            return value.text.isEmpty ? nil : value.text
        }
        return [
            PopupCommand(id: "chat", group: .ai, title: "Chat", shortcutTitle: "Toggle AI Chat", detail: store.isPrivate ? "Unavailable in private windows" : "Chat about the pages in this tab", icon: "bubble.left.and.bubble.right", isEnabled: !store.isPrivate, menuAction: #selector(toggleChat)) { store.showChat() },
            PopupCommand(id: "summarize", group: .ai, title: "Summarize Page", detail: "Summarize the active page using Local AI", icon: "text.alignleft", isEnabled: canSummarizePage) { [weak self] in self?.summarizePage() },
            PopupCommand(id: "explainSelection", group: .ai, title: "Explain Selected", detail: "Explain the selected webpage text using Local AI", icon: "text.bubble", isEnabled: selection != nil && canSummarizePage) { [weak self] in self?.discussCommandSelection(explain: true) },
            PopupCommand(id: "summarizeSelection", group: .ai, title: "Summarize Selected", detail: "Summarize the selected webpage text using Local AI", icon: "text.alignleft", isEnabled: selection != nil && canSummarizePage) { [weak self] in self?.discussCommandSelection(explain: false) },
            PopupCommand(id: "favorite", group: .tabs, title: favorite == nil ? "Add Tab to Favorites" : "Remove Tab from Favorites",
                detail: "Save the active pane’s website", icon: "star", isEnabled: favorite != nil || store.canFavorite(tab)) {
                    if let favorite { store.removeFavorite(favorite.id) } else { store.requestFavorite(tab.id) }
                },
            PopupCommand(id: "duplicate", group: .tabs, title: "Duplicate Tab", detail: "Copy all panes into a new tab", icon: "plus.square.on.square") {
                store.duplicateTab(tab.id)
            },
            PopupCommand(id: "close", group: .tabs, title: "Close Tab", detail: tab.isPinned ? "Unpin the tab to close it" : "Close all panes in this tab",
                icon: "xmark", isEnabled: !tab.isPinned, menuAction: #selector(closeTab)) { store.closeTab(tab.id) },
            PopupCommand(id: "pinTab", group: .tabs, title: tab.isPinned ? "Unpin Tab" : "Pin Tab", detail: "Protect all panes from closing", icon: "pin") {
                store.setTabPinned(tab.id, pinned: !tab.isPinned)
            },
            PopupCommand(id: "returnPinned", group: .panes, title: "Return to Pinned URL",
                detail: "Open the address saved when this pane was pinned", icon: "arrow.uturn.backward",
                isEnabled: store.pinnedReturnAddress(tab.focusedPane) != nil) {
                    store.returnToPinnedURL(tab.focusedPane)
                },
            PopupCommand(id: "pinPane", group: .panes, title: store.isPanePinned(tab.focusedPane) ? "Unpin Pane" : "Pin Pane",
                detail: "Protect the active pane from closing", icon: "pin.fill") {
                    store.setPanePinned(tab.focusedPane, pinned: !store.isPanePinned(tab.focusedPane))
                },
            PopupCommand(id: "sidebar", title: store.sidebarVisible ? "Hide Sidebar" : "Show Sidebar", shortcutTitle: "Toggle Sidebar",
                detail: "Toggle sidebar", icon: "sidebar.left", menuAction: #selector(toggleSidebar)) { store.sidebarVisible.toggle() },
            PopupCommand(id: "settings", title: "Settings…", detail: "Browser preferences", icon: "gearshape", menuAction: #selector(showSettings)) { [weak self] in self?.showSettings() },
            PopupCommand(id: "back", group: .panes, title: "Back", detail: "Go back in the active pane", icon: "chevron.left",
                isEnabled: store.canGoBack(from: tab.focusedPane), menuAction: #selector(back)) { [weak self] in self?.back() },
            PopupCommand(id: "forward", group: .panes, title: "Forward", detail: "Go forward in the active pane", icon: "chevron.right",
                isEnabled: page?.canGoForward == true && page?.isStartPage == false, menuAction: #selector(forward)) { [weak self] in self?.forward() },
            PopupCommand(id: "reload", group: .panes, title: "Reload Page", detail: "Refresh the active page", icon: "arrow.clockwise",
                isEnabled: page?.isStartPage == false, menuAction: #selector(reload)) { [weak self] in self?.reload() },
            PopupCommand(id: "copyPageURL", group: .panes, title: "Copy Page URL", detail: "Copy the active pane’s address to the clipboard",
                icon: "doc.on.doc", isEnabled: currentPageAddress != nil, menuAction: #selector(copyPageURL)) { [weak self] in self?.copyPageURL() },
            PopupCommand(id: "print", title: "Print…", detail: "Print the active page", icon: "printer",
                isEnabled: printablePage != nil, menuAction: #selector(printPage)) { [weak self] in self?.printPage() },
            PopupCommand(id: "changelog", title: "What’s New", detail: "Features, improvements, and fixes in every release", icon: "sparkles", menuAction: #selector(showChangelog)) { store.showChangelog() },
            PopupCommand(id: "history", title: "View History", detail: "Browse visited pages", icon: "clock", menuAction: #selector(showHistory)) { [weak self] in self?.showHistory() },
            PopupCommand(id: "chat-history", group: .ai, title: "Show AI Chat History", detail: "Restore conversations and their pane layouts", icon: "clock.arrow.circlepath", isEnabled: !store.isPrivate) { store.showChatHistory() },
            PopupCommand(id: "devTools", title: findSurface?.isDeveloperToolsVisible == true ? "Hide Developer Tools" : "Show Developer Tools",
                detail: "Toggle dev tools / Web Inspector", icon: "hammer", isEnabled: activeWebPage != nil, menuAction: #selector(showWebInspector)) { [weak self] in self?.showWebInspector() }
        ]
    }

    @objc private func openLocation() { store.requestAddress() }
    private var currentPageAddress: String? {
        guard let context = browserWindows.active else { return nil }
        if let key = focusedWindow(), key !== context.window, !context.addressPanel.owns(key) { return nil }
        let store = context.store
        let tab = store.selectedTab
        return store.existingController(for: tab.focusedPane)?.address ?? tab.pages.first { $0.id == tab.focusedPane }?.address
    }

    @objc private func copyPageURL() {
        writePageAddress(to: .general)
    }

    func writePageAddress(to pasteboard: NSPasteboard) {
        guard let address = currentPageAddress else { return }
        pasteboard.clearContents()
        pasteboard.setString(address, forType: .string)
    }

    private var activeWebPage: PageController? {
        guard let context = browserWindows.active,
              focusedWindow() == nil || focusedWindow() === context.window || focusedWindow().map(context.addressPanel.owns) == true,
              let page = context.store.existingController(for: context.store.selectedTab.focusedPane),
              !page.isStartPage, page.error == nil,
              let surface = page.webView.superview as? WebSurfaceHost,
              !surface.isHiddenOrHasHiddenAncestor else { return nil }
        return page
    }
    private var findSurface: WebSurfaceHost? { activeWebPage?.webView.superview as? WebSurfaceHost }

    // @lat: [[lat.md/architecture/web-pages#Page printing]]
    private var printablePage: PageController? {
        guard printOperation == nil, NSPrintOperation.current == nil,
              let window, window.isVisible, !window.isMiniaturized, window.attachedSheet == nil,
              let page = activeWebPage, page.webView.window === window else { return nil }
        return page
    }

    @objc func printPage() {
        guard let page = printablePage, let window = page.webView.window else { return }
        let operation = page.webView.printOperation(with: .shared)
        operation.jobTitle = page.title
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        printOperation = operation
        operation.runModal(for: window, delegate: self,
            didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
    }

    @objc private func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        if printOperation === operation { printOperation = nil }
    }
    @objc func showWebInspector() {
        if let page = activeWebPage, findSurface?.isDeveloperToolsVisible == true { page.webView.closeInspector() }
        else { showDeveloperTools(console: false) }
    }
    @objc func showJavaScriptConsole() { showDeveloperTools(console: true) }
    private func showDeveloperTools(console: Bool) {
        guard let page = activeWebPage else { return }
        if (page.webView.superview as? WebSurfaceHost)?.showDeveloperTools(console: console) != true {
            let alert = NSAlert()
            alert.messageText = "Open Web Inspector in Safari"
            alert.informativeText = "This WebKit version cannot open the inspector directly. In Safari, enable developer features in Settings → Advanced, then choose this Bend page from the Develop menu."
            if let window { alert.beginSheetModal(for: window) }
        }
    }
    @objc func findInPage(_ sender: NSMenuItem) {
        guard let action = NSTextFinder.Action(rawValue: sender.tag) else { return }
        findSurface?.performFindAction(action)
    }

    // @lat: [[lat.md/architecture/settings#Page zoom]]
    private static let pageZoomLevels = PageZoom.levels.map { CGFloat($0) }

    private func pageZoomLevel(_ direction: Int, current: CGFloat) -> CGFloat {
        if direction > 0 { return Self.pageZoomLevels.first { $0 > current + 0.001 } ?? Self.pageZoomLevels.last! }
        if direction < 0 { return Self.pageZoomLevels.last { $0 < current - 0.001 } ?? Self.pageZoomLevels.first! }
        return 1
    }

    @objc func zoomPage(_ sender: NSMenuItem) {
        guard let page = activeWebPage else { return }
        page.setPageZoom(pageZoomLevel(sender.tag, current: page.webView.pageZoom))
    }
    @objc func showChangelog() {
        addressPanel?.dismiss(restoreFocus: false)
        store.showChangelog()
    }

    func showReleaseNotesIfUpdated(tracker: WhatsNewTracker = WhatsNewTracker(), show: Bool = true) {
        guard tracker.consumeUpgrade() else { return }
        let context = browserWindows.windows.first(where: { !$0.store.isPrivate }) ?? browserWindows.newWindow(show: false)
        context.addressPanel.dismiss(restoreFocus: false)
        context.store.showChangelog()
        if show { context.window.makeKeyAndOrderFront(nil) }
    }

    @objc private func showHistory() {
        addressPanel?.dismiss(restoreFocus: false)
        store.showHistory()
        window?.makeKeyAndOrderFront(nil)
    }
    @objc private func closePane() { closeFocusedWindow(focusedWindow()) }

    func closeFocusedWindow(_ keyWindow: NSWindow?) {
        let context = browserWindows.active
        if let keyWindow, keyWindow !== context?.window, context?.addressPanel.owns(keyWindow) != true {
            keyWindow.performClose(nil)
            return
        }
        guard let context else { return }
        guard !context.store.isPanePinned(context.store.selectedTab.focusedPane) else { return }
        if context.addressPanel.cancelInitialEntryIfPresented() { return }
        context.addressPanel.dismiss(restoreFocus: false)
        let store = context.store
        if (store.isPrivate || browserWindows.windows.count > 1),
           store.session.workspaces.flatMap(\.tabs).count == 1, store.selectedTab.pages.count == 1 {
            context.window.performClose(nil)
        } else {
            store.closePane(store.selectedTab.focusedPane)
        }
    }
    @objc private func closeTab() { store.closeTab(store.selectedTab.id) }
    @objc private func reopenClosed() {
        addressPanel?.dismiss(restoreFocus: false)
        store.reopenClosed()
        window?.makeKeyAndOrderFront(nil)
    }
    private func shortcutCommand(_ item: NSMenuItem) -> PopupCommand? {
        guard let id = item.representedObject as? String,
              let context = browserWindows.active,
              focusedWindow() == nil || focusedWindow() === context.window else { return nil }
        return popupCommands().first { $0.id == id }
    }

    @objc func runPaletteShortcut(_ item: NSMenuItem) {
        guard let command = shortcutCommand(item) else { return }
        if command.id == "explainSelection" || command.id == "summarizeSelection" {
            guard canSummarizePage, let context = browserWindows.active,
                  let page = activeWebPage else { return }
            let tab = context.store.selectedTab
            let revision = page.aiNavigationRevision
            Task {
                guard let text = try? await page.selectedPageText(), !text.isEmpty,
                      browserWindows.active === context, activeWebPage === page,
                      store.selectedTab.id == tab.id, page.aiNavigationRevision == revision else { return }
                store.showChat()
                store.chats[tab.id]?.discussSelection(text, explain: command.id == "explainSelection")
            }
        } else if command.isEnabled {
            command.perform()
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(runPaletteShortcut(_:)) {
            guard let command = shortcutCommand(menuItem) else { return false }
            menuItem.title = command.title
            if command.id == "explainSelection" || command.id == "summarizeSelection" {
                return canSummarizePage && activeWebPage != nil
            }
            return command.isEnabled
        }
        if menuItem.action == #selector(toggleChat) {
            guard let context = browserWindows.active else { return false }
            menuItem.title = context.store.openChats.contains(context.store.selectedTab.id) ? "Hide Chat" : "Show Chat"
            return !context.store.isPrivate
        }
        if menuItem.action == #selector(copyPageURL) { return currentPageAddress != nil }
        if menuItem.action == #selector(printPage) { return printablePage != nil }
        if menuItem.action == #selector(showWebInspector) || menuItem.action == #selector(showJavaScriptConsole) {
            if menuItem.action == #selector(showWebInspector) {
                menuItem.title = findSurface?.isDeveloperToolsVisible == true ? "Close Web Inspector" : "Show Web Inspector"
            }
            return activeWebPage != nil
        }
        if menuItem.action == #selector(findInPage(_:)) { return findSurface != nil }
        if menuItem.action == #selector(zoomPage(_:)) {
            guard let page = activeWebPage else { return false }
            return pageZoomLevel(menuItem.tag, current: page.webView.pageZoom) != page.webView.pageZoom
        }
        if menuItem.action == #selector(closeTab) { return !store.selectedTab.isPinned }
        if menuItem.action == #selector(closePane) {
            if let key = focusedWindow(), key !== window, addressPanel?.owns(key) != true { return true }
            return !store.isPanePinned(store.selectedTab.focusedPane)
        }
        return menuItem.action == #selector(reopenClosed) ? store.canReopenClosed : true
    }
    @objc private func splitRight() { store.split(.horizontal) }
    @objc private func splitBelow() { store.split(.vertical) }
    @objc private func zoomPane() { store.toggleZoom(store.selectedTab.focusedPane) }
    private var canSummarizePage: Bool {
        guard let context = browserWindows.active, !context.store.isPrivate else { return false }
        let store = context.store
        if let chat = store.chats[store.selectedTab.id] { return chat.canSummarize }
        let page = store.selectedTab.pages.first { $0.id == store.selectedTab.focusedPane }
        return ["http", "https"].contains(URL(string: page?.address ?? "")?.scheme ?? "")
    }

    private func discussCommandSelection(explain: Bool) {
        guard canSummarizePage, let selection = commandSelection,
              selection.pane == store.selectedTab.focusedPane,
              store.existingController(for: selection.pane)?.aiNavigationRevision == selection.revision,
              !selection.text.isEmpty else { return }
        store.showChat()
        store.chats[store.selectedTab.id]?.discussSelection(selection.text, explain: explain)
    }

    @objc func summarizePage() {
        guard let context = browserWindows.active, !context.store.isPrivate else { return }
        context.store.showChat()
        context.store.chats[context.store.selectedTab.id]?.summarize()
    }

    @objc func toggleChat() {
        guard let context = browserWindows.active, !context.store.isPrivate else { return }
        let store = context.store
        if store.openChats.contains(store.selectedTab.id) { store.openChats.remove(store.selectedTab.id) }
        else { store.showChat() }
    }
    @objc private func toggleSidebar() { store.sidebarVisible.toggle() }
    @objc private func reload() { if !focused.isStartPage { focused.webView.reload() } }
    @objc private func back() { store.goBack(from: store.selectedTab.focusedPane) }
    @objc private func forward() { focused.webView.goForward() }
    @objc private func about() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: AppProfile.current.name,
            .credits: NSAttributedString(string: "A native, tiled WebKit browser. Inspired by Rex.")])
    }
}
