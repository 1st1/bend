import AppKit
import SwiftUI
import BrowseCore

@main
@MainActor
enum BrowseApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let store = BrowserStore()
    private var window: NSWindow!
    private var clickMonitor: Any?
    private var addressPanel: AddressPanelController!
    private var settingsWindow: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1420, height: 880),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Browse"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // Let AppKit position the traffic lights at the custom header's height,
        // including during resize and full-screen transitions.
        window.toolbarStyle = .unified
        window.toolbar = NSToolbar(identifier: "BrowseTitlebar")
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 780, height: 500)
        window.contentView = makeWindowContent()
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("BrowseMainWindow")
        addressPanel = AddressPanelController(store: store, parentWindow: window)
        store.onAddressRequested = { [weak self] paneID in self?.addressPanel.show(for: paneID) }
        store.onSettingsRequested = { [weak self] in self?.showSettings() }
        if #available(macOS 15.4, *) { store.extensions.browserWindow = window }
        installMenus()
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            if let content = event.window?.contentView {
                var hit = content.hitTest(content.convert(event.locationInWindow, from: nil))
                while let view = hit {
                    if let browser = view as? FocusWebView { browser.onFocus?(); break }
                    hit = view.superview
                }
            }
            return event
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { store.save() }
    func windowDidBecomeKey(_ notification: Notification) {
        if #available(macOS 15.4, *) { store.extensions.controller.didFocusWindow(store.extensions.window) }
    }
    func windowDidResignKey(_ notification: Notification) {
        if #available(macOS 15.4, *) { store.extensions.controller.didFocusWindow(nil) }
    }

    // @lat: [[architecture#Sidebar materials]]
    private func makeWindowContent() -> NSView {
        let content = NSHostingView(rootView: BrowserView(store: store).ignoresSafeArea())
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            // The window supplies its own outer corner clipping. One glass
            // surface spans the sidebar, titlebar area, and exposed pane gaps.
            glass.cornerRadius = 0
            glass.contentView = content
            return glass
        }
        return content
    }

    private func installMenus() {
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
        add("New Tab", #selector(newTab), "t", to: file)
        add("Open Location…", #selector(openLocation), "l", to: file)
        file.addItem(.separator())
        add("Close Pane", #selector(closePane), "w", to: file)
        add("Close Tab", #selector(closeTab), "w", modifiers: [.command, .shift], to: file)
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
    @objc private func newTab() { store.newTab() }
    @objc private func showSettings() {
        addressPanel.dismiss(restoreFocus: false)
        if settingsWindow == nil { settingsWindow = SettingsWindowController(store: store) }
        settingsWindow?.show()
    }
    @objc private func openLocation() { store.requestAddress() }
    @objc private func showHistory() {
        addressPanel.dismiss(restoreFocus: false)
        store.showHistory()
        window.makeKeyAndOrderFront(nil)
    }
    @objc private func closePane() { store.closePane(store.selectedTab.focusedPane) }
    @objc private func closeTab() { store.closeTab(store.selectedTab.id) }
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
