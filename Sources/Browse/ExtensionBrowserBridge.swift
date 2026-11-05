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

    var pages: [Page] { store?.session.workspaces.flatMap(\.tabs).flatMap(\.pages) ?? [] }

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
        let selected = store?.selectedTab.focusedPane
        if selected != activeID, let selected, let tab = tabs[selected] {
            let previous = activeID.flatMap { tabs[$0] }
            activeID = selected
            controller.didActivateTab(tab, previousActiveTab: previous)
        }
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
        [window] + documents.values.map { $0 as any WKWebExtensionWindow }
    }
    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        if let document = documents.values.first(where: { $0.nativeWindow.isKeyWindow }) { return document }
        return browserWindow?.isKeyWindow == true || !presentsWindows ? window : nil
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for context: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionTab)?, Error?) -> Void) {
        guard let store else { completionHandler(nil, failure("The browser is closed.")); return }
        let url = configuration.url ?? URL(string: "browse://start")!
        if url.scheme == context.baseURL.scheme, url.host == context.baseURL.host {
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
        guard let webView = target?.webView?(for: context), webView.window != nil,
              let popover = action.popupPopover else {
            completionHandler(failure("Select a visible web page before opening this extension.")); return
        }
        popup?.close()
        popup = popover
        popover.behavior = .transient
        popover.show(relativeTo: NSRect(x: max(0, webView.bounds.width - 40), y: 36, width: 1, height: 1),
            of: webView, preferredEdge: .maxY)
        completionHandler(nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action,
        forExtensionContext context: WKWebExtensionContext) { objectWillChange.send() }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?, for context: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        let allowed = approve(context.webExtension.displayName ?? "Extension", details: permissions.map(\.rawValue).sorted())
        // Optional runtime grants last for this app session. Restart requires a new approval.
        completionHandler(allowed ? permissions : [], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns patterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?, for context: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        let allowed = approve(context.webExtension.displayName ?? "Extension", details: patterns.map(\.string).sorted())
        completionHandler(allowed ? patterns : [], nil)
    }

    func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?, for context: WKWebExtensionContext,
        completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        let allowed = approve(context.webExtension.displayName ?? "Extension", details: urls.map { $0.host ?? $0.absoluteString }.sorted())
        completionHandler(allowed ? urls : [], nil)
    }
}

@available(macOS 15.4, *)
@MainActor
final class ExtensionWindow: NSObject, WKWebExtensionWindow {
    weak var manager: ExtensionManager?
    init(manager: ExtensionManager) { self.manager = manager }
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        manager?.pages.compactMap { manager?.tabs[$0.id] } ?? []
    }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        guard let manager, let id = manager.store?.selectedTab.focusedPane else { return nil }
        return manager.tabs[id]
    }
    func frame(for context: WKWebExtensionContext) -> CGRect { manager?.browserWindow?.frame ?? .zero }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { manager?.browserWindow?.screen?.frame ?? .zero }
    func focus(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        manager?.browserWindow?.makeKeyAndOrderFront(nil); completionHandler(nil)
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
    var page: Page? { manager?.pages.first { $0.id == id } }
    var pageController: PageController? { manager?.store?.existingController(for: id) }
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { manager?.window }
    func parentTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        guard let manager, let parent = manager.store?.linkOpeners[id] else { return nil }
        return manager.tabs[parent]
    }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { pageController?.webView }
    func title(for context: WKWebExtensionContext) -> String? { pageController?.title ?? page?.address }
    func url(for context: WKWebExtensionContext) -> URL? { (pageController?.address ?? page?.address).flatMap(URL.init(string:)) }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !(pageController?.isLoading ?? false) }
    func isSelected(for context: WKWebExtensionContext) -> Bool { manager?.store?.selectedTab.pages.contains { $0.id == id } ?? false }
    func activate(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        manager?.store?.revealPage(id); completionHandler(nil)
    }
    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let page, let store = manager?.store else {
            completionHandler(manager?.failure("This URL cannot open in a browser pane.")); return
        }
        if context.isLoaded, url.scheme == context.baseURL.scheme, url.host == context.baseURL.host,
           let configuration = context.webViewConfiguration {
            store.controller(for: page).navigateExtension(url, configuration: configuration)
        } else if ["https", "http"].contains(url.scheme ?? "") {
            store.controller(for: page).navigate(url.absoluteString)
        } else {
            completionHandler(manager?.failure("This URL cannot open in a browser pane.")); return
        }
        completionHandler(nil)
    }
    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        if fromOrigin { pageController?.webView.reloadFromOrigin() } else { pageController?.webView.reload() }
        completionHandler(nil)
    }
    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        pageController?.webView.goBack(); completionHandler(nil)
    }
    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        pageController?.webView.goForward(); completionHandler(nil)
    }
    func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        manager?.store?.closePage(id); completionHandler(nil)
    }
}
