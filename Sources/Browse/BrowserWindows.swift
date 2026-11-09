import AppKit
import SwiftUI
import BrowseCore

// @lat: [[architecture#Browser windows]]
@MainActor
final class BrowserWindows {
    let sharedStore: BrowserStore
    private let root: URL
    private(set) var windows: [BrowserWindowSession] = []
    private weak var lastActive: BrowserWindowSession?
    var onSettings: (() -> Void)?
    private var terminating = false

    init(root: URL? = nil, persistentExtensions: Bool = true) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BrowsePrototype", isDirectory: true)
        sharedStore = BrowserStore(sessionFile: self.root.appendingPathComponent("session.json"),
                                   persistentExtensions: persistentExtensions)
    }

    var active: BrowserWindowSession? {
        windows.first { $0.window.isKeyWindow } ?? lastActive ?? windows.last
    }

    func restore(show: Bool = true) {
        guard windows.isEmpty else { return }
        let file = root.appendingPathComponent("windows.json")
        let saved = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String].self, from: $0) }
        let ids = saved?.filter { $0 == "main" || UUID(uuidString: $0) != nil } ?? []
        var seen: Set<String> = []
        for id in ids.isEmpty ? ["main"] : ids where seen.insert(id).inserted {
            _ = create(id: id, fresh: false, show: show)
        }
    }

    @discardableResult
    func newWindow(show: Bool = true) -> BrowserWindowSession {
        let result = create(id: UUID().uuidString, fresh: true, show: show)
        save()
        if show { result.store.requestAddress() }
        return result
    }

    private func create(id: String, fresh: Bool, show: Bool, address: String = "browse://start") -> BrowserWindowSession {
        let store = id == "main" ? sharedStore : BrowserStore(
            sessionFile: root.appendingPathComponent("Windows/\(id).json"), sharedStore: sharedStore)
        if fresh {
            let tab = BrowserTab(title: "New tab", pages: [Page(address: address)])
            store.session.workspaces = [Workspace(name: "Tabs", tabs: [tab])]
            store.session.selectedTab = tab.id
        }
        let previous = active?.window
        let context = BrowserWindowSession(id: id, store: store)
        context.onFocus = { [weak self, weak context] in self?.lastActive = context }
        context.onClose = { [weak self, weak context] in
            guard let self, let context else { return }
            self.windows.removeAll { $0 === context }
            if self.lastActive === context { self.lastActive = self.windows.last }
            // Retain the final closed window for the next launch. Explicit quit
            // saves the whole open set before AppKit tears down any windows.
            if !self.terminating, !self.windows.isEmpty { self.save() }
        }
        store.onNewWindowDrop = { [weak self, weak store] tab, pane, point in
            guard let self, let store else { return false }
            return self.detach(tab: tab, pane: pane, from: store, at: point) != nil
        }
        store.onNewLinkWindow = { [weak self] address in self?.openLinkInNewWindow(address) }
        store.onSettingsRequested = { [weak self] in self?.onSettings?() }
        store.onEmptiedByTransfer = { [weak self, weak context] destination in
            guard let self, let context, self.windows.count > 1,
                  self.windows.contains(where: { $0 === context }),
                  let target = self.windows.first(where: { $0.store === destination }) else { return }
            if context.window.isVisible { target.window.makeKeyAndOrderFront(nil) }
            context.window.close()
        }
        windows.append(context)
        lastActive = context
        if fresh, let previous {
            context.window.cascadeTopLeft(from: NSPoint(x: previous.frame.minX + 24, y: previous.frame.maxY - 24))
        }
        if show { context.window.makeKeyAndOrderFront(nil) }
        return context
    }

    func openLinkInNewWindow(_ address: String) {
        let context = create(id: UUID().uuidString, fresh: true, show: false, address: address)
        context.window.makeKeyAndOrderFront(nil)
        save()
    }

    // @lat: [[architecture#Dragging into a new window]]
    @discardableResult
    func detach(tab tabID: UUID, pane paneID: UUID?, from source: BrowserStore, at point: NSPoint) -> BrowserWindowSession? {
        guard let original = windows.first(where: { $0.store === source }),
              let tab = source.session.workspaces.flatMap(\.tabs).first(where: { $0.id == tabID }),
              paneID == nil || tab.pages.contains(where: { $0.id == paneID }) else { return nil }
        let visible = NSScreen.screens.first { $0.frame.contains(point) }?.visibleFrame
            ?? original.window.screen?.visibleFrame ?? original.window.frame
        let size = NSSize(width: min(original.window.frame.width, visible.width),
                          height: min(original.window.frame.height, visible.height))
        let frame = NSRect(x: min(max(point.x - 160, visible.minX), visible.maxX - size.width),
                           y: min(max(point.y + 124 - size.height, visible.minY), visible.maxY - size.height),
                           width: size.width, height: size.height)
        let context = create(id: UUID().uuidString, fresh: true, show: false)
        context.window.setFrame(frame, display: false)
        guard source.transfer(tab: tabID, pane: paneID, to: context.store, at: .emptyWindow) else {
            context.window.close()
            return nil
        }
        context.window.makeKeyAndOrderFront(nil)
        save()
        return context
    }

    func save() {
        sharedStore.save()
        for context in windows where context.store !== sharedStore { context.store.save() }
        guard !windows.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONEncoder().encode(windows.map(\.id)).write(to: root.appendingPathComponent("windows.json"), options: .atomic)
        } catch { sharedStore.persistenceError = "Open windows could not be saved: \(error.localizedDescription)" }
    }

    func prepareToQuit() { terminating = true; sharedStore.downloads.shutdown(); save() }
}

@MainActor
final class BrowserWindowSession: NSObject, NSWindowDelegate {
    let id: String
    let store: BrowserStore
    let window: BrowseWindow
    private(set) var addressPanel: AddressPanelController!
    var onFocus: (() -> Void)?
    var onClose: (() -> Void)?

    init(id: String, store: BrowserStore) {
        self.id = id; self.store = store
        window = BrowseWindow(contentRect: NSRect(x: 0, y: 0, width: 1420, height: 880),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.browserStore = store
        window.title = "Bend"
        window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified; window.toolbar = NSToolbar(identifier: "BrowseTitlebar")
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.isOpaque = false; window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 780, height: 500)
        window.delegate = self; window.isReleasedWhenClosed = false
        window.center()
        let frameName = id == "main" ? "BrowseMainWindow" : "BrowseWindow-\(id)"
        window.setFrameAutosaveName(frameName)
        window.setFrameUsingName(frameName)
        if #available(macOS 15.4, *) { store.extensions.attachWindow(window, store: store) }
        let content = NSHostingView(rootView: BrowserView(store: store).ignoresSafeArea())
        if #available(macOS 26.0, *) { window.contentView = BrowserWindowGlass(store: store, content: content) }
        else { window.contentView = content }
        addressPanel = AddressPanelController(store: store, parentWindow: window)
        store.onAddressRequested = { [weak self] paneID in self?.addressPanel.show(for: paneID) }
        InputDiagnostics.transition(.windowOpen, .created, window: window)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        onFocus?()
        if #available(macOS 15.4, *) { store.extensions.focusWindow(window) }
    }
    func windowDidResignKey(_ notification: Notification) {
        if #available(macOS 15.4, *) { store.extensions.controller.didFocusWindow(nil) }
    }
    // @lat: [[architecture#Fullscreen chrome]]
    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions) -> NSApplication.PresentationOptions {
        proposedOptions.union(.autoHideToolbar)
    }
    func windowWillEnterFullScreen(_ notification: Notification) {
        addressPanel.dismiss(restoreFocus: false)
        // The empty unified toolbar is only for windowed traffic-light alignment.
        // Hide its row so fullscreen rollover uses AppKit's compact titlebar.
        window.toolbar?.isVisible = false
    }
    func windowDidEnterFullScreen(_ notification: Notification) {
        store.isFullScreen = true
    }
    func windowWillExitFullScreen(_ notification: Notification) {
        addressPanel.dismiss(restoreFocus: false)
    }
    func windowDidExitFullScreen(_ notification: Notification) {
        window.toolbar?.isVisible = true
        store.isFullScreen = false
    }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        window.toolbar?.isVisible = true
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        !store.session.workspaces.flatMap(\.tabs).contains { $0.isPinned }
    }

    func windowWillClose(_ notification: Notification) {
        addressPanel.dismiss(restoreFocus: false)
        if #available(macOS 15.4, *) { store.extensions.detachWindow(window) }
        store.stopWindow()
        window.contentView = nil
        onClose?()
    }
}
