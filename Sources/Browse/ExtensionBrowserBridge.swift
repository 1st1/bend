import AppKit
import WebKit
import BrowseCore

@available(macOS 15.4, *)
extension ExtensionManager: WKWebExtensionControllerDelegate {
    func webExtensionController(_ controller: WKWebExtensionController, connectUsing port: WKWebExtension.MessagePort,
        for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        do { try nativeMessaging.connect(port, context: context); completionHandler(nil) }
        catch { completionHandler(error) }
    }

    func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any,
        toApplicationWithIdentifier applicationIdentifier: String?, for context: WKWebExtensionContext,
        replyHandler: @escaping (Any?, Error?) -> Void) {
        nativeMessaging.send(message, name: applicationIdentifier, context: context, reply: replyHandler)
    }

    var browserStores: [BrowserStore] {
        hasRegisteredWindows ? browserWindows.compactMap(\.owningStore) : store.map { [$0] } ?? []
    }
    var pages: [Page] { browserStores.flatMap { $0.session.workspaces.flatMap(\.tabs).flatMap(\.pages) } }
    func store(for pageID: UUID) -> BrowserStore? {
        browserStores.first { $0.session.workspaces.flatMap(\.tabs).contains { $0.pages.contains { $0.id == pageID } } }
    }
    func window(for store: BrowserStore) -> ExtensionWindow {
        browserWindows.first { $0.owningStore === store } ?? window
    }
    func attachWindow(_ native: NSWindow, store: BrowserStore) {
        let adapter = hasRegisteredWindows || store.isPrivate ? ExtensionWindow(manager: self) : window
        if !hasRegisteredWindows, store.isPrivate { controller.didCloseWindow(window) }
        hasRegisteredWindows = true
        adapter.owningStore = store; adapter.nativeWindow = native
        browserWindows.append(adapter)
        if adapter !== window { controller.didOpenWindow(adapter) }
        synchronizeTabs()
    }
    func focusWindow(_ native: NSWindow) {
        guard let adapter = browserWindows.first(where: { $0.nativeWindow === native }) else { return }
        store = adapter.owningStore; browserWindow = native
        synchronizeTabs()
        controller.didFocusWindow(adapter)
    }
    func detachWindow(_ native: NSWindow) {
        guard let adapter = browserWindows.first(where: { $0.nativeWindow === native }) else { return }
        browserWindows.removeAll { $0 === adapter }
        if browserWindow === native || store === adapter.owningStore {
            store = browserWindows.last?.owningStore; browserWindow = browserWindows.last?.nativeWindow
        }
        synchronizeTabs()
        controller.didCloseWindow(adapter)
        adapter.owningStore = nil; adapter.nativeWindow = nil
        adapter.manager = nil
    }

    func synchronizeTabs() {
        let ids = Set(pages.map(\.id))
        for id in Array(tabs.keys) where !ids.contains(id) {
            if let tab = tabs.removeValue(forKey: id) { controller.didCloseTab(tab) }
        }
        for page in pages where tabs[page.id] == nil {
            let tab = ExtensionTab(id: page.id, manager: self)
            tabs[page.id] = tab
            controller.didOpenTab(tab)
        }
        let owners = browserStores
        activePanes = activePanes.filter { key, _ in owners.contains { ObjectIdentifier($0) == key } }
        for owner in owners {
            let key = ObjectIdentifier(owner)
            let selected = owner.selectedTab.focusedPane
            guard selected != activePanes[key], let tab = tabs[selected] else { continue }
            let previous = activePanes[key].flatMap { tabs[$0] }
            InputDiagnostics.transition(.extensionActivation, .changed, paneID: selected, relatedPaneID: activePanes[key])
            activePanes[key] = selected
            controller.didActivateTab(tab, previousActiveTab: previous)
        }
        activeID = store?.selectedTab.focusedPane
    }

    func pageChanged(_ id: UUID) {
        guard let tab = tabs[id], let page = tab.pageController else { return }
        var changes: WKWebExtension.TabChangedProperties = []
        if tab.lastURL != page.address { changes.insert(.URL) }
        if tab.lastTitle != page.title { changes.insert(.title) }
        if tab.lastLoading != page.isLoading { changes.insert(.loading) }
        tab.lastURL = page.address; tab.lastTitle = page.title; tab.lastLoading = page.isLoading
        if !changes.isEmpty { controller.didChangeTabProperties(changes, for: tab) }
    }

    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor context: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        (hasRegisteredWindows ? browserWindows : [window]).filter { !$0.isPrivate(for: context) || context.hasAccessToPrivateData } + documents.values.map { $0 as any WKWebExtensionWindow }
    }
    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        if let document = documents.values.first(where: { $0.nativeWindow.isKeyWindow }) { return document }
        if let active = browserWindows.first(where: { $0.nativeWindow?.isKeyWindow == true }) {
            return !active.isPrivate(for: context) || context.hasAccessToPrivateData ? active : nil
        }
        return !hasRegisteredWindows && (browserWindow?.isKeyWindow == true || !presentsWindows) ? window : nil
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for context: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionTab)?, Error?) -> Void) {
        guard let store = (configuration.window as? ExtensionWindow)?.store ?? store else {
            completionHandler(nil, failure("The browser is closed.")); return
        }
        guard !store.isPrivate || context.hasAccessToPrivateData else {
            completionHandler(nil, failure("This extension is not enabled in private mode.")); return
        }
        // Safari extensions use this URL for their default new-tab gesture.
        let requestedURL = configuration.url
        let url = requestedURL?.absoluteString == "favorites://"
            ? URL(string: "browse://start")!
            : requestedURL ?? URL(string: "browse://start")!
        if url.scheme == context.baseURL.scheme, url.host == context.baseURL.host {
            guard !store.isPrivate else {
                completionHandler(nil, failure(PageController.privateExtensionPageError)); return
            }
            do { completionHandler(try openDocument(url: url, context: context, active: configuration.shouldBeActive), nil) }
            catch { completionHandler(nil, error) }
            return
        }
        guard ["http", "https", "browse"].contains(url.scheme ?? "") else {
            completionHandler(nil, failure("This extension URL cannot open in a browser pane. Use Extension Settings for its options page.")); return
        }
        let previous = store.session.selectedTab
        store.newTab(address: url.absoluteString)
        let page = store.selectedTab.pages[0]
        _ = store.controller(for: page)
        if !configuration.shouldBeActive { store.select(previous) }
        synchronizeTabs()
        completionHandler(tabs[page.id], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor context: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void) {
        do { try showOptions(context); completionHandler(nil) } catch { completionHandler(error) }
    }

    func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action,
        for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        let target = action.associatedTab ?? activeID.flatMap { tabs[$0] }
        guard (target as? ExtensionTab)?.store?.isPrivate != true else {
            completionHandler(failure("Extension popups are unavailable in private windows because their website storage cannot be isolated.")); return
        }
        guard let webView = target?.webView?(for: context), webView.window != nil,
              let popover = action.popupPopover else {
            completionHandler(failure("Select a visible web page before opening this extension.")); return
        }
        InputDiagnostics.transition(.extensionPopup, .requested, view: webView)
        popup?.close()
        popup = popover
        popupPaneID = (webView as? FocusWebView)?.diagnosticPaneID
        popover.behavior = .transient
        popover.show(relativeTo: NSRect(x: max(0, webView.bounds.width - 40), y: 36, width: 1, height: 1),
            of: webView, preferredEdge: .maxY)
        InputDiagnostics.transition(.extensionPopup, .shown, view: webView)
        completionHandler(nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action,
        forExtensionContext context: WKWebExtensionContext) { objectWillChange.send() }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?, for context: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        let allowed = approve(context.webExtension.displayName ?? "Extension", details: permissions.map(\.rawValue).sorted(), context: context, sessionOnly: true)
        // Optional runtime grants last for this app session. Restart requires a new approval.
        completionHandler(allowed ? permissions : [], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns patterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?, for context: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        let allowed = approve(context.webExtension.displayName ?? "Extension", details: patterns.map(\.string).sorted(), context: context, sessionOnly: true)
        completionHandler(allowed ? patterns : [], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?, for context: WKWebExtensionContext,
        completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        let allowed = approve(context.webExtension.displayName ?? "Extension", details: urls.map(\.absoluteString).sorted(), context: context, sessionOnly: true)
        completionHandler(allowed ? urls : [], nil)
    }
}

@available(macOS 15.4, *)
@MainActor
final class ExtensionWindow: NSObject, WKWebExtensionWindow {
    weak var manager: ExtensionManager?
    weak var owningStore: BrowserStore?
    weak var nativeWindow: NSWindow?
    var store: BrowserStore? { owningStore ?? manager?.store }
    var native: NSWindow? { nativeWindow ?? manager?.browserWindow }
    init(manager: ExtensionManager) { self.manager = manager }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { store?.isPrivate ?? false }
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        guard !isPrivate(for: context) || context.hasAccessToPrivateData else { return [] }
        return store?.session.workspaces.flatMap(\.tabs).flatMap(\.pages).compactMap { manager?.tabs[$0.id] } ?? []
    }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        guard !isPrivate(for: context) || context.hasAccessToPrivateData,
              let manager, let id = store?.selectedTab.focusedPane else { return nil }
        return manager.tabs[id]
    }
    func frame(for context: WKWebExtensionContext) -> CGRect { native?.frame ?? .zero }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { native?.screen?.frame ?? .zero }
    func focus(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        InputDiagnostics.transition(.extensionWindowFocus, .requested, window: native, paneID: store?.selectedTab.focusedPane)
        native?.makeKeyAndOrderFront(nil); completionHandler(nil)
    }
}

@available(macOS 15.4, *)
@MainActor
final class ExtensionTab: NSObject, WKWebExtensionTab {
    let id: UUID
    weak var manager: ExtensionManager?
    var lastURL: String?
    var lastTitle: String?
    var lastLoading: Bool?
    init(id: UUID, manager: ExtensionManager) { self.id = id; self.manager = manager }
    func canAccess(_ context: WKWebExtensionContext) -> Bool {
        guard let store else { return false }
        return !store.isPrivate || context.hasAccessToPrivateData
    }
    var page: Page? { manager?.pages.first { $0.id == id } }
    var store: BrowserStore? { manager?.store(for: id) }
    var pageController: PageController? { store?.existingController(for: id) }
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        // WebKit needs the owning window to classify this tab as private.
        guard let store else { return nil }; return manager?.window(for: store)
    }
    func parentTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        guard canAccess(context), let manager, let parent = store?.linkOpeners[id] else { return nil }
        return manager.tabs[parent]
    }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { canAccess(context) ? pageController?.webView : nil }
    func title(for context: WKWebExtensionContext) -> String? { canAccess(context) ? (pageController?.title ?? page?.address) : nil }
    func url(for context: WKWebExtensionContext) -> URL? { canAccess(context) ? (pageController?.address ?? page?.address).flatMap(URL.init(string:)) : nil }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !(pageController?.isLoading ?? false) }
    func isSelected(for context: WKWebExtensionContext) -> Bool { store?.selectedTab.pages.contains { $0.id == id } ?? false }
    func activate(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard canAccess(context) else { completionHandler(manager?.failure("This extension cannot access this private tab.")); return }
        InputDiagnostics.transition(.extensionTabAction, .requested, paneID: id, flags: ["activate": true])
        store?.revealPage(id)
        if let store { manager?.window(for: store).native?.makeKeyAndOrderFront(nil) }
        completionHandler(nil)
    }
    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard canAccess(context) else { completionHandler(manager?.failure("This extension cannot access this private tab.")); return }
        InputDiagnostics.transition(.extensionTabAction, .requested, paneID: id, flags: ["load": true])
        guard let page, let store else {
            completionHandler(manager?.failure("This URL cannot open in a browser pane.")); return
        }
        if store.isPrivate, url.scheme == context.baseURL.scheme, url.host == context.baseURL.host {
            completionHandler(manager?.failure(PageController.privateExtensionPageError)); return
        }
        if context.isLoaded, url.scheme == context.baseURL.scheme, url.host == context.baseURL.host,
           let configuration = store.extensionConfiguration(for: context) {
            store.controller(for: page).navigateExtension(url, configuration: configuration)
        } else if ["https", "http"].contains(url.scheme ?? "") {
            store.controller(for: page).navigate(url.absoluteString)
        } else {
            completionHandler(manager?.failure("This URL cannot open in a browser pane.")); return
        }
        completionHandler(nil)
    }
    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard canAccess(context) else { completionHandler(manager?.failure("This extension cannot access this private tab.")); return }
        InputDiagnostics.transition(.extensionTabAction, .requested, paneID: id, flags: ["reload": true])
        if fromOrigin { pageController?.webView.reloadFromOrigin() } else { pageController?.webView.reload() }
        completionHandler(nil)
    }
    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard canAccess(context) else { completionHandler(manager?.failure("This extension cannot access this private tab.")); return }
        InputDiagnostics.transition(.extensionTabAction, .requested, paneID: id, flags: ["back": true])
        pageController?.webView.goBack(); completionHandler(nil)
    }
    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard canAccess(context) else { completionHandler(manager?.failure("This extension cannot access this private tab.")); return }
        InputDiagnostics.transition(.extensionTabAction, .requested, paneID: id, flags: ["forward": true])
        pageController?.webView.goForward(); completionHandler(nil)
    }
    func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard canAccess(context) else { completionHandler(manager?.failure("This extension cannot access this private tab.")); return }
        InputDiagnostics.transition(.extensionTabAction, .requested, paneID: id, flags: ["close": true])
        guard store?.isPanePinned(id) != true else {
            completionHandler(NSError(domain: "Bend", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unpin this pane before closing it."]))
            return
        }
        store?.closePage(id); completionHandler(nil)
    }
}
