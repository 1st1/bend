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
        let appMenu = NSMenu(title: "Browse")
        appMenu.addItem(withTitle: "About Browse", action: #selector(about), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        add("Settings…", #selector(showSettings), ",", to: appMenu)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Browse", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Browse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
        settingsWindow?.show()
    }
    @objc private func openLocation() { store.requestAddress() }
    @objc private func showHistory() {
        addressPanel?.dismiss(restoreFocus: false)
        store.showHistory()
        window?.makeKeyAndOrderFront(nil)
    }
    @objc private func closePane() {
        if addressPanel?.cancelNewTabIfPresented() == true { return }
        addressPanel?.dismiss(restoreFocus: false)
        store.closePane(store.selectedTab.focusedPane)
    }
    @objc private func closeTab() { store.closeTab(store.selectedTab.id) }
    @objc private func reopenClosed() {
        addressPanel?.dismiss(restoreFocus: false)
        store.reopenClosed()
        window?.makeKeyAndOrderFront(nil)
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(reopenClosed) ? store.canReopenClosed : true
    }
    @objc private func splitRight() { store.split(.horizontal) }
    @objc private func splitBelow() { store.split(.vertical) }
    @objc private func zoomPane() { store.toggleZoom(store.selectedTab.focusedPane) }
    @objc private func toggleSidebar() { store.sidebarVisible.toggle() }
    @objc private func reload() { if !focused.isStartPage { focused.webView.reload() } }
    @objc private func back() { focused.webView.goBack() }
    @objc private func forward() { focused.webView.goForward() }
    @objc private func about() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Browse", .applicationVersion: "0.1 Prototype",
            .credits: NSAttributedString(string: "A native, tiled WebKit browser. Inspired by Rex.")])
    }
}
