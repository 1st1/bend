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

    init(browserWindows: BrowserWindows = BrowserWindows(), focusedWindow: @escaping () -> NSWindow? = { NSApp.keyWindow }) {
        self.browserWindows = browserWindows
        self.focusedWindow = focusedWindow
        super.init()
    }
    private var clickMonitor: Any?
    private var settingsWindow: SettingsWindowController?
    private(set) var printOperation: NSPrintOperation?
    private var browserWindowsReady = false
    private var pendingExternalURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        InputDiagnostics.transition(.launch, .started)
        browserWindows.onSettings = { [weak self] section in self?.presentSettings(section: section) }
        restoreBrowserWindows()
        installMenus()
        AppUpdater.shared.start()
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { event in
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
        add("Show JavaScript Console", #selector(showJavaScriptConsole), "c", modifiers: [.command, .option], to: develop)
        append(develop, to: main)
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
    @objc private func newTab() { store.newTab() }
    @objc private func showSettings() {
        presentSettings()
    }
    private func presentSettings(section: SettingsSection? = nil) {
        addressPanel?.dismiss(restoreFocus: false)
        if settingsWindow == nil { settingsWindow = SettingsWindowController(store: browserWindows.sharedStore) }
        settingsWindow?.show(section: section, centeredOn: browserWindows.active?.window.screen)
    }
    // @lat: [[lat.md/architecture/commands#Command popup]]
    @objc func showCommands() {
        guard let context = browserWindows.active else { return }
        let tabID = context.store.selectedTab.id
        let paneID = context.store.selectedTab.focusedPane
        context.addressPanel.showCommands(for: paneID) { [weak self, weak context] in
            guard let self, let context, self.browserWindows.active === context,
                  context.store.selectedTab.id == tabID,
                  context.store.selectedTab.focusedPane == paneID else { return [] }
            return self.popupCommands()
        }
    }

    func popupCommands() -> [PopupCommand] {
        let store = store
        let tab = store.selectedTab
        let favorite = store.favorite(for: tab)
        return [
            PopupCommand(id: "favorite", title: favorite == nil ? "Add Tab to Favorites" : "Remove Tab from Favorites",
                detail: "Save the active pane’s website", icon: "star", isEnabled: favorite != nil || store.canFavorite(tab)) {
                    if let favorite { store.removeFavorite(favorite.id) } else { store.requestFavorite(tab.id) }
                },
            PopupCommand(id: "duplicate", title: "Duplicate Tab", detail: "Copy all panes into a new tab", icon: "plus.square.on.square") {
                store.duplicateTab(tab.id)
            },
            PopupCommand(id: "close", title: "Close Tab", detail: tab.isPinned ? "Unpin the tab to close it" : "Close all panes in this tab",
                icon: "xmark", isEnabled: !tab.isPinned) { store.closeTab(tab.id) },
            PopupCommand(id: "pinTab", title: tab.isPinned ? "Unpin Tab" : "Pin Tab", detail: "Protect all panes from closing", icon: "pin") {
                store.setTabPinned(tab.id, pinned: !tab.isPinned)
            },
            PopupCommand(id: "returnPinned", title: "Return to Pinned URL",
                detail: "Open the address saved when this pane was pinned", icon: "arrow.uturn.backward",
                isEnabled: store.pinnedReturnAddress(tab.focusedPane) != nil) {
                    store.returnToPinnedURL(tab.focusedPane)
                },
            PopupCommand(id: "pinPane", title: store.isPanePinned(tab.focusedPane) ? "Unpin Pane" : "Pin Pane",
                detail: "Protect the active pane from closing", icon: "pin.fill") {
                    store.setPanePinned(tab.focusedPane, pinned: !store.isPanePinned(tab.focusedPane))
                },
            PopupCommand(id: "sidebar", title: store.sidebarVisible ? "Hide Sidebar" : "Show Sidebar",
                detail: "Toggle sidebar · ⇧⌘S", icon: "sidebar.left") { store.sidebarVisible.toggle() },
            PopupCommand(id: "settings", title: "Settings…", detail: "Browser preferences · ⌘,", icon: "gearshape") { [weak self] in self?.showSettings() },
            PopupCommand(id: "print", title: "Print…", detail: "Print the active page · ⌘P", icon: "printer",
                isEnabled: printablePage != nil) { [weak self] in self?.printPage() },
            PopupCommand(id: "history", title: "View History", detail: "Browse visited pages · ⌘Y", icon: "clock") { [weak self] in self?.showHistory() },
            PopupCommand(id: "devTools", title: findSurface?.isDeveloperToolsVisible == true ? "Hide Developer Tools" : "Show Developer Tools",
                detail: "Toggle dev tools / Web Inspector · ⇧⌘I", icon: "hammer", isEnabled: activeWebPage != nil) { [weak self] in self?.showWebInspector() }
        ]
    }

    @objc private func openLocation() { store.requestAddress() }
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
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
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
    @objc private func toggleSidebar() { store.sidebarVisible.toggle() }
    @objc private func reload() { if !focused.isStartPage { focused.webView.reload() } }
    @objc private func back() { focused.webView.goBack() }
    @objc private func forward() { focused.webView.goForward() }
    @objc private func about() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: AppProfile.current.name,
            .credits: NSAttributedString(string: "A native, tiled WebKit browser. Inspired by Rex.")])
    }
}
