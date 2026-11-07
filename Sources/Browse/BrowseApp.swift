import AppKit
import SwiftUI
import BrowseCore

@main
@MainActor
enum BrowseApp {
    static func main() {
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

    init(browserWindows: BrowserWindows = BrowserWindows()) {
        self.browserWindows = browserWindows
        super.init()
    }
    private var clickMonitor: Any?
    private var settingsWindow: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        InputDiagnostics.transition(.launch, .started)
        browserWindows.onSettings = { [weak self] in self?.showSettings() }
        browserWindows.restore()
        installMenus()
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { event in
            InputDiagnostics.record(.application, event: event)
            defer { InputDiagnostics.record(.applicationReturned, event: event) }
            guard event.type == .leftMouseDown else { return event }
            if let content = event.window?.contentView {
                var hit = content.hitTest(content.convert(event.locationInWindow, from: nil))
                while let view = hit {
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
        let appMenu = NSMenu(title: "Bend")
        appMenu.addItem(withTitle: "About Bend", action: #selector(about), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        add("Settings…", #selector(showSettings), ",", to: appMenu)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Bend", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Bend", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        append(appMenu, to: main)

        let file = NSMenu(title: "File")
        add("New Window", #selector(newWindow), "n", to: file)
        add("New Tab", #selector(newTab), "t", to: file)
        add("Open Location…", #selector(openLocation), "l", to: file)
        file.addItem(.separator())
        add("Close Pane", #selector(closePane), "w", to: file)
        add("Close Tab", #selector(closeTab), "w", modifiers: [.command, .shift], to: file)
        add("Reopen Closed Pane or Tab", #selector(reopenClosed), "t", modifiers: [.command, .shift], to: file)
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
    @objc private func newTab() { store.newTab() }
    @objc private func showSettings() {
        addressPanel?.dismiss(restoreFocus: false)
        if settingsWindow == nil { settingsWindow = SettingsWindowController(store: browserWindows.sharedStore) }
        settingsWindow?.show(centeredOn: browserWindows.active?.window.screen)
    }
    @objc private func openLocation() { store.requestAddress() }
    private var activeWebPage: PageController? {
        guard let context = browserWindows.active,
              NSApp.keyWindow == nil || NSApp.keyWindow === context.window,
              let page = context.store.existingController(for: context.store.selectedTab.focusedPane),
              !page.isStartPage, page.error == nil,
              let surface = page.webView.superview as? WebSurfaceHost,
              !surface.isHiddenOrHasHiddenAncestor else { return nil }
        return page
    }
    private var findSurface: WebSurfaceHost? { activeWebPage?.webView.superview as? WebSurfaceHost }
    @objc func findInPage(_ sender: NSMenuItem) {
        guard let action = NSTextFinder.Action(rawValue: sender.tag) else { return }
        findSurface?.performFindAction(action)
    }

    // @lat: [[architecture#Page zoom]]
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
    @objc private func closePane() { closeFocusedWindow(NSApp.keyWindow) }

    func closeFocusedWindow(_ keyWindow: NSWindow?) {
        let context = browserWindows.active
        if let keyWindow, keyWindow !== context?.window, context?.addressPanel.owns(keyWindow) != true {
            keyWindow.performClose(nil)
            return
        }
        guard let context else { return }
        if context.addressPanel.cancelInitialEntryIfPresented() { return }
        context.addressPanel.dismiss(restoreFocus: false)
        let store = context.store
        if browserWindows.windows.count > 1,
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
        if menuItem.action == #selector(findInPage(_:)) { return findSurface != nil }
        if menuItem.action == #selector(zoomPage(_:)) {
            guard let page = activeWebPage else { return false }
            return pageZoomLevel(menuItem.tag, current: page.webView.pageZoom) != page.webView.pageZoom
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
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Bend", .applicationVersion: "0.1 Prototype",
            .credits: NSAttributedString(string: "A native, tiled WebKit browser. Inspired by Rex.")])
    }
}
