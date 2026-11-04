import AppKit
import Combine
import WebKit
import BrowseCore

@MainActor
final class BrowserStore: ObservableObject {
    @Published var session: BrowserSession
    @Published var sidebarVisible = true
    @Published var zoomedPane: UUID?
    @Published private(set) var paneMoveRevision = 0
    var onAddressRequested: ((UUID) -> Void)?
    var onSettingsRequested: (() -> Void)?
    private var extensionStorage: AnyObject?
    private let persistentExtensions: Bool
    @available(macOS 15.4, *)
    var extensions: ExtensionManager {
        if let manager = extensionStorage as? ExtensionManager { return manager }
        let manager = ExtensionManager(root: sessionFile.deletingLastPathComponent().appendingPathComponent("Extensions"), persistent: persistentExtensions)
        extensionStorage = manager
        manager.store = self
        manager.start()
        return manager
    }
    @Published var persistenceError: String?
    @Published private(set) var history = BrowsingHistory()
    @Published private(set) var historyError: String?
    private var browsers: [UUID: PageController] = [:]
    private struct ClosedItem {
        let tab: BrowserTab
        let workspaceID: UUID
        let tabIndex: Int
        let paneID: UUID?
        let replacementID: UUID?
    }
    @Published private var closedItems: [ClosedItem] = []
    var canReopenClosed: Bool { !closedItems.isEmpty }
    // Only main-frame link openings populate this map. Subframe source IDs are
    // not exposed by public WKNavigationAction and must not be fabricated.
    private(set) var linkOpeners: [UUID: UUID] = [:]
    private var pendingSave: Task<Void, Never>?
    private let sessionFile: URL
    private let historyFile: URL
    private var pendingHistorySave: Task<Void, Never>?
    private var historyDirty = false
    private var historyWritable = true

    init(sessionFile: URL? = nil, persistentExtensions: Bool = true, extensionManager: AnyObject? = nil) {
        self.persistentExtensions = persistentExtensions
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BrowsePrototype", isDirectory: true)
        self.sessionFile = sessionFile ?? root.appendingPathComponent("session.json")
        historyFile = self.sessionFile.deletingLastPathComponent().appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: self.sessionFile),
           let restored = try? JSONDecoder().decode(BrowserSession.self, from: data), restored.isValid {
            session = restored
        } else { session = BrowserSession() }
        if FileManager.default.fileExists(atPath: historyFile.path) {
            do {
                let restored = try JSONDecoder().decode(BrowsingHistory.self, from: Data(contentsOf: historyFile))
                guard restored.isValid else { throw CocoaError(.fileReadCorruptFile) }
                history = restored
            } catch {
                historyWritable = false
                historyError = "Saved history could not be read. Clear history to reset it."
            }
        }
        extensionStorage = extensionManager
        if #available(macOS 15.4, *), let manager = extensionManager as? ExtensionManager {
            manager.store = self
            manager.start()
        }
    }

    var selectedTab: BrowserTab {
        session.workspaces.flatMap(\.tabs).first { $0.id == session.selectedTab }!
    }

    func editTab(_ id: UUID? = nil, _ change: (inout BrowserTab) -> Void) {
        let target = id ?? session.selectedTab
        for wi in session.workspaces.indices {
            if let ti = session.workspaces[wi].tabs.firstIndex(where: { $0.id == target }) {
                change(&session.workspaces[wi].tabs[ti]); saveSoon(); return
            }
        }
    }

    func select(_ id: UUID) { session.selectedTab = id; zoomedPane = nil; saveSoon() }
    func focus(_ id: UUID) {
        guard selectedTab.focusedPane != id, selectedTab.pages.contains(where: { $0.id == id }) else { return }
        editTab { $0.focusedPane = id }
    }
    func split(_ axis: SplitAxis) {
        zoomedPane = nil
        editTab { $0.split(axis: axis) }
        requestAddress()
    }

    func requestAddress(for paneID: UUID? = nil) {
        let target = paneID ?? selectedTab.focusedPane
        guard selectedTab.pages.contains(where: { $0.id == target }) else { return }
        focus(target)
        onAddressRequested?(target)
    }
    func openPane(address: String, toRightOf source: UUID, fromMainFrame: Bool = true) {
        guard let tab = session.workspaces.flatMap(\.tabs).first(where: { $0.pages.contains { $0.id == source } }) else { return }
        select(tab.id)
        editTab(tab.id) {
            $0.split(axis: .horizontal, after: source, address: address)
            if fromMainFrame { linkOpeners[$0.focusedPane] = source }
        }
    }
    func resize(_ id: UUID, fraction: Double) { editTab { $0.layout = $0.layout.resizing(id, to: fraction) } }
    @discardableResult
    func movePane(_ source: UUID, beside target: UUID, edge: PaneDropEdge, in tabID: UUID, from sourceTabID: UUID? = nil) -> Bool {
        guard selectedTab.id == tabID, zoomedPane == nil else { return false }
        if let sourceTabID, sourceTabID != tabID {
            var next = session
            guard next.transferPane(source, from: sourceTabID, beside: target, in: tabID, edge: edge) else { return false }
            refreshTransferredTitles(&next)
            session = next
            saveSoon()
            paneMoveRevision += 1
            return true
        }
        guard let layout = selectedTab.layout.moving(source, beside: target, edge: edge) else { return false }
        editTab(tabID) { $0.layout = layout; $0.focusedPane = source }
        paneMoveRevision += 1
        return true
    }

    @discardableResult
    func detachPane(_ source: UUID, from sourceTabID: UUID, into workspaceID: UUID) -> Bool {
        var next = session
        let title = browsers[source]?.title ?? session.workspaces.flatMap(\.tabs)
            .first(where: { $0.id == sourceTabID })?.title ?? "New tab"
        guard next.detachPane(source, from: sourceTabID, into: workspaceID, title: title) != nil else { return false }
        zoomedPane = nil
        refreshTransferredTitles(&next)
        session = next
        saveSoon()
        paneMoveRevision += 1
        return true
    }

    private func refreshTransferredTitles(_ next: inout BrowserSession) {
        for wi in next.workspaces.indices {
            for ti in next.workspaces[wi].tabs.indices {
                if let first = next.workspaces[wi].tabs[ti].pages.first, let title = browsers[first.id]?.title {
                    next.workspaces[wi].tabs[ti].title = title
                }
            }
        }
    }
    func toggleZoom(_ id: UUID) { focus(id); zoomedPane = zoomedPane == id ? nil : id }

    func newTab(in workspace: UUID? = nil, address: String = "browse://start", linkOpener: UUID? = nil) {
        let index = session.workspaces.firstIndex { $0.id == workspace }
            ?? session.workspaces.firstIndex { $0.tabs.contains { $0.id == session.selectedTab } } ?? 0
        let tab = BrowserTab(title: address == "browse://history" ? "History" : "New tab", pages: [Page(address: address)])
        if let linkOpener { linkOpeners[tab.pages[0].id] = linkOpener }
        session.workspaces[index].tabs.append(tab); select(tab.id)
        if address == "browse://start" { requestAddress() }
    }

    func newWorkspace(name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let workspace = Workspace(name: name)
        session.workspaces.append(workspace); select(workspace.tabs[0].id)
        requestAddress()
    }

    func showHistory() {
        for workspace in session.workspaces {
            if let tab = workspace.tabs.first(where: { $0.pages.contains { $0.address == "browse://history" } }),
               let page = tab.pages.first(where: { $0.address == "browse://history" }) {
                select(tab.id); focus(page.id); return
            }
        }
        newTab(address: "browse://history")
    }

    func recordVisit(url: String, title: String, at date: Date = Date()) {
        guard history.record(url: url, title: title, at: date) else { return }
        saveHistorySoon()
    }

    func recordHistoryChoice(url: String, query: String) {
        history.recordChoice(url: url, query: query)
        saveHistorySoon()
    }

    func removeHistory(url: String) {
        history.remove(url: url)
        historyDirty = true
        saveHistory()
    }

    func clearHistory() {
        history.clear()
        historyWritable = true
        historyDirty = true
        saveHistory()
    }

    private func saveHistorySoon() {
        historyDirty = true
        pendingHistorySave?.cancel()
        pendingHistorySave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            self?.saveHistory()
        }
    }

    func saveHistory() {
        pendingHistorySave?.cancel()
        pendingHistorySave = nil
        guard historyDirty, historyWritable else { return }
        do {
            try FileManager.default.createDirectory(at: historyFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(history).write(to: historyFile, options: .atomic)
            historyDirty = false
            historyError = nil
        } catch { historyError = "History could not be saved: \(error.localizedDescription)" }
    }

    func closeTab(_ id: UUID) {
        for wi in session.workspaces.indices {
            guard let ti = session.workspaces[wi].tabs.firstIndex(where: { $0.id == id }) else { continue }
            let closed = snapshot(session.workspaces[wi].tabs[ti])
            for page in session.workspaces[wi].tabs[ti].pages { browsers.removeValue(forKey: page.id)?.webView.stopLoading() }
            session.workspaces[wi].tabs.remove(at: ti)
            let needsReplacement = session.workspaces[wi].tabs.isEmpty
            if needsReplacement { session.workspaces[wi].tabs.append(BrowserTab()) }
            rememberClosed(.init(tab: closed, workspaceID: session.workspaces[wi].id, tabIndex: ti, paneID: nil,
                replacementID: needsReplacement ? session.workspaces[wi].tabs[0].id : nil))
            if session.selectedTab == id { select(session.workspaces[wi].tabs[min(ti, session.workspaces[wi].tabs.count - 1)].id) }
            if needsReplacement && session.selectedTab == session.workspaces[wi].tabs[0].id { requestAddress() }
            saveSoon(); return
        }
    }

    func closePane(_ id: UUID) {
        guard selectedTab.pages.contains(where: { $0.id == id }) else { return }
        closePage(id)
    }

    private func snapshot(_ tab: BrowserTab) -> BrowserTab {
        var result = tab
        for index in result.pages.indices {
            if let controller = browsers[result.pages[index].id] { result.pages[index].address = controller.address }
        }
        return result
    }

    private func rememberClosed(_ item: ClosedItem) {
        closedItems.append(item)
        if closedItems.count > 50 { closedItems.removeFirst(closedItems.count - 50) }
    }

    // @lat: [[architecture#Reopening closed panes and tabs]]
    func reopenClosed() {
        guard let item = closedItems.popLast() else { return }
        let wi = session.workspaces.firstIndex { $0.id == item.workspaceID } ?? 0
        if let paneID = item.paneID, let pageIndex = item.tab.pages.firstIndex(where: { $0.id == paneID }) {
            let page = item.tab.pages[pageIndex]
            if let ti = session.workspaces[wi].tabs.firstIndex(where: { $0.id == item.tab.id }) {
                var tab = session.workspaces[wi].tabs[ti]
                tab.layout = tab.layout.restoring(paneID, from: item.tab.layout)
                    ?? tab.layout.splitting(tab.focusedPane, with: paneID, axis: .horizontal)
                tab.pages.insert(page, at: min(pageIndex, tab.pages.count))
                tab.focusedPane = paneID
                session.workspaces[wi].tabs[ti] = tab
            } else {
                var tab = BrowserTab(title: item.tab.title, pages: [page])
                tab.id = item.tab.id
                session.workspaces[wi].tabs.insert(tab, at: min(item.tabIndex, session.workspaces[wi].tabs.count))
            }
        } else {
            if let replacementID = item.replacementID,
               let index = session.workspaces[wi].tabs.firstIndex(where: { $0.id == replacementID }) {
                let replacement = session.workspaces[wi].tabs[index]
                if replacement.pages.count == 1, replacement.pages[0].address == "browse://start",
                   (browsers[replacement.pages[0].id]?.address ?? "browse://start") == "browse://start" {
                    browsers.removeValue(forKey: replacement.pages[0].id)?.webView.stopLoading()
                    session.workspaces[wi].tabs.remove(at: index)
                }
            }
            session.workspaces[wi].tabs.insert(item.tab, at: min(item.tabIndex, session.workspaces[wi].tabs.count))
        }
        select(item.tab.id)
    }

    func controller(for page: Page) -> PageController {
        if let existing = browsers[page.id] { return existing }
        let extensionURL = URL(string: page.address).flatMap { $0.scheme == "webkit-extension" ? $0 : nil }
        let controller = PageController(address: extensionURL == nil ? page.address : "browse://start", configure: { [weak self] configuration in
            if #available(macOS 15.4, *) { self?.extensions.configure(configuration) }
        })
        controller.onStateChanged = { [weak self] in
            if #available(macOS 15.4, *) { self?.extensions.pageChanged(page.id) }
        }
        controller.onNavigation = { [weak self] address, title in
            guard let self else { return }
            for workspace in self.session.workspaces {
                if let tab = workspace.tabs.first(where: { $0.pages.contains { $0.id == page.id } }) {
                    self.editTab(tab.id) { tab in
                        if let index = tab.pages.firstIndex(where: { $0.id == page.id }) { tab.pages[index].address = address }
                        if tab.pages.first?.id == page.id { tab.title = title }
                    }
                    break
                }
            }
        }
        controller.onNewTab = { [weak self] address in self?.newTab(address: address) }
        controller.onNewPane = { [weak self] address in self?.openPane(address: address, toRightOf: page.id) }
        controller.onNewLink = { [weak self] address, adjacent, mainFrame in
            if adjacent { self?.openPane(address: address, toRightOf: page.id, fromMainFrame: mainFrame) }
            else { self?.newTab(address: address, linkOpener: mainFrame ? page.id : nil) }
        }
        controller.onFocus = { [weak self] in self?.focus(page.id) }
        controller.onVisit = { [weak self] url, title in self?.recordVisit(url: url, title: title) }
        controller.onHistoryTitleChanged = { [weak self] url, title in
            guard let self else { return }
            self.history.updateTitle(title, for: url)
            self.saveHistorySoon()
        }
        browsers[page.id] = controller
        if #available(macOS 15.4, *), let extensionURL {
            let manager = extensions
            Task { [weak controller] in
                await manager.restorationTask?.value
                guard let controller, self.browsers[page.id] === controller,
                      controller.address == "browse://start" else { return }
                guard let context = manager.controller.extensionContext(for: extensionURL), context.isLoaded,
                      let configuration = context.webViewConfiguration else {
                    controller.error = "This extension page is unavailable. Enable its extension in Settings."
                    return
                }
                controller.navigateExtension(extensionURL, configuration: configuration)
            }
        }
        return controller
    }

    func existingController(for pageID: UUID) -> PageController? { browsers[pageID] }

    func revealPage(_ id: UUID) {
        guard let tab = session.workspaces.flatMap(\.tabs).first(where: { $0.pages.contains { $0.id == id } }) else { return }
        select(tab.id); focus(id)
    }

    func closePage(_ id: UUID) {
        guard let wi = session.workspaces.firstIndex(where: { $0.tabs.contains { $0.pages.contains { $0.id == id } } }),
              let ti = session.workspaces[wi].tabs.firstIndex(where: { $0.pages.contains { $0.id == id } }) else { return }
        let tab = session.workspaces[wi].tabs[ti]
        if tab.pages.count == 1 { closeTab(tab.id); return }
        rememberClosed(.init(tab: snapshot(tab), workspaceID: session.workspaces[wi].id, tabIndex: ti, paneID: id, replacementID: nil))
        editTab(tab.id) { $0.closePane(id) }
        if zoomedPane == id { zoomedPane = nil }
        browsers.removeValue(forKey: id)?.webView.stopLoading()
    }

    func saveSoon() {
        let pageIDs = Set(session.workspaces.flatMap(\.tabs).flatMap(\.pages).map(\.id))
        linkOpeners = linkOpeners.filter { pageIDs.contains($0.key) && pageIDs.contains($0.value) }
        if #available(macOS 15.4, *), let manager = extensionStorage as? ExtensionManager { manager.synchronizeTabs() }
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            self?.save()
        }
    }

    func save() {
        do {
            try FileManager.default.createDirectory(at: sessionFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(session).write(to: sessionFile, options: .atomic)
            persistenceError = nil
        } catch { persistenceError = "Session could not be saved: \(error.localizedDescription)" }
        saveHistory()
    }
}

// @lat: [[architecture#WebKit integration]]
@MainActor
class FocusWebView: WKWebView {
    var onFocus: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onFocus?(); super.mouseDown(with: event) }
    override func becomeFirstResponder() -> Bool { onFocus?(); return super.becomeFirstResponder() }
}

@MainActor
final class PageController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published private(set) var webView: FocusWebView
    private let configure: (WKWebViewConfiguration) -> Void
    private var extensionOrigin: URL?
    @Published var address: String
    @Published var title = "New tab"
    @Published var favicon: NSImage?
    private var faviconTask: Task<Void, Never>?
    @Published var isLoading = false
    @Published var progress = 0.0
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var error: String?
    @Published var isStartPage = true
    var onNavigation: ((String, String) -> Void)?
    var onStateChanged: (() -> Void)?
    var onNewTab: ((String) -> Void)?
    var onNewPane: ((String) -> Void)?
    var onNewLink: ((String, Bool, Bool) -> Void)?
    var onFocus: (() -> Void)?
    private var observations: [NSKeyValueObservation] = []
    var onVisit: ((String, String) -> Void)?
    var onHistoryTitleChanged: ((String, String) -> Void)?
    private var completedAddress: String?
    private var lastReportedAddress = ""
    private var lastReportedTitle = ""

    // WebKit's default user agent omits Safari's product tokens. Some sites
    // consequently serve a legacy, fixed-width page to an otherwise modern engine.
    static let websiteApplicationName: String = {
        let safariVersion = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari")
            .flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }
        let version = safariVersion.map { $0.split(separator: ".").prefix(2).joined(separator: ".") } ?? "17.0"
        return "Version/\(version) Safari/605.1.15 Browse/0.1"
    }()

    init(address: String, webView suppliedWebView: FocusWebView? = nil, configure: @escaping (WKWebViewConfiguration) -> Void = { _ in }) {
        self.address = address
        self.configure = configure
        let configuration = WKWebViewConfiguration()
        configuration.applicationNameForUserAgent = Self.websiteApplicationName
        configuration.websiteDataStore = .default()
        configure(configuration)
        webView = suppliedWebView ?? FocusWebView(frame: .zero, configuration: configuration)
        super.init()
        observeWebView()
        navigate(address)
    }

    private func observeWebView() {
        webView.navigationDelegate = self; webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = true
        webView.onFocus = { [weak self] in self?.onFocus?() }
        observations = [
            webView.observe(\.estimatedProgress) { [weak self] _, _ in Task { @MainActor in self?.refresh() } },
            webView.observe(\.isLoading) { [weak self] _, _ in Task { @MainActor in self?.refresh() } },
            webView.observe(\.title) { [weak self] _, _ in Task { @MainActor in self?.refresh() } },
            webView.observe(\.url) { [weak self] _, _ in Task { @MainActor in self?.refresh() } }
        ]
    }

    private func replaceWebView(configuration: WKWebViewConfiguration) {
        observations.removeAll()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.onFocus = nil
        webView.stopLoading()
        webView = FocusWebView(frame: webView.frame, configuration: configuration)
        canGoBack = false; canGoForward = false
        observeWebView()
    }

    // Only the extension host may authorize a top-level extension document.
    func navigateExtension(_ url: URL, configuration: WKWebViewConfiguration) {
        if extensionOrigin?.scheme != url.scheme || extensionOrigin?.host != url.host {
            extensionOrigin = url
            replaceWebView(configuration: configuration)
        }
        load(url)
    }

    func unloadExtension(at origin: URL) {
        guard extensionOrigin?.scheme == origin.scheme, extensionOrigin?.host == origin.host else { return }
        navigate("browse://start")
        error = "This extension page is unavailable. Enable its extension in Settings."
    }

    func navigate(_ input: String) {
        guard let url = AddressResolver.resolve(input) else { error = "Enter a web address or search phrase."; return }
        if extensionOrigin != nil {
            extensionOrigin = nil
            let configuration = WKWebViewConfiguration()
            configuration.applicationNameForUserAgent = Self.websiteApplicationName
            configuration.websiteDataStore = .default()
            configure(configuration)
            replaceWebView(configuration: configuration)
        }
        load(url)
    }

    private func load(_ url: URL) {
        resetFavicon()
        error = nil; address = url.absoluteString
        completedAddress = nil
        isStartPage = url.scheme == "browse"
        if isStartPage {
            webView.stopLoading()
            title = address == "browse://history" ? "History" : (address == "browse://guide" ? "Tiling guide" : "New tab")
            reportNavigation()
        } else { webView.load(URLRequest(url: url)) }
    }

    func refresh() {
        defer { onStateChanged?() }
        isLoading = webView.isLoading; progress = webView.estimatedProgress
        canGoBack = webView.canGoBack; canGoForward = webView.canGoForward
        if !isStartPage {
            if let url = webView.url { address = url.absoluteString }
            title = webView.title?.isEmpty == false ? webView.title! : (webView.url?.host ?? "New tab")
            reportNavigation()
            if let completedAddress, !isLoading, error == nil {
                if completedAddress != address {
                    recordCompletedVisit()
                } else if title != historyTitle {
                    historyTitle = title
                    onHistoryTitleChanged?(address, title)
                }
            }
        }
    }

    private func reportNavigation() {
        guard address != lastReportedAddress || title != lastReportedTitle else { return }
        lastReportedAddress = address; lastReportedTitle = title
        onNavigation?(address, title)
    }

    private var historyTitle = ""

    private func recordCompletedVisit() {
        guard !isStartPage, error == nil, let url = webView.url,
              BrowsingHistory.webAddress(url.absoluteString) != nil else { return }
        completedAddress = url.absoluteString
        historyTitle = title
        onVisit?(url.absoluteString, title)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        resetFavicon()
        completedAddress = nil
        if !isStartPage { error = nil }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refresh()
        recordCompletedVisit()
        guard !isStartPage, let url = webView.url else { return }
        faviconTask?.cancel()
        faviconTask = Task { [weak self] in
            let candidates = await FaviconLoader.candidates(in: webView, pageURL: url)
            guard !Task.isCancelled else { return }
            let image = await FaviconLoader.load(candidates)
            guard !Task.isCancelled else { return }
            self?.favicon = image
        }
    }

    private func resetFavicon() {
        faviconTask?.cancel()
        faviconTask = nil
        favicon = nil
    }

    deinit { faviconTask?.cancel() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { show(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { show(error) }
    func show(_ failure: Error) {
        completedAddress = nil
        if (failure as NSError).code != NSURLErrorCancelled { error = failure.localizedDescription }
        refresh()
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { error = "This page stopped responding. Reload to continue." }
    private func openCommandClickedLink(_ action: WKNavigationAction) -> Bool {
        // WebKit reports left-click as 1 (a button mask), unlike NSEvent's zero-based buttonNumber.
        guard action.navigationType == .linkActivated, action.modifierFlags.contains(.command),
              action.buttonNumber == 1, let url = action.request.url,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let onNewPane else { return false }
        if let onNewLink { onNewLink(url.absoluteString, true, action.sourceFrame.isMainFrame) }
        else { onNewPane(url.absoluteString) }
        return true
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if openCommandClickedLink(action) { decisionHandler(.cancel); return }
        if #available(macOS 15.4, *),
           let context = webView.configuration.webExtensionController?.extensionContext(for: url), context.isLoaded {
            // WebKit still enforces web_accessible_resources for embedded frames.
            let ownDocument = extensionOrigin?.scheme == url.scheme && extensionOrigin?.host == url.host
            decisionHandler(action.targetFrame?.isMainFrame == false || ownDocument ? .allow : .cancel)
            return
        }
        if extensionOrigin != nil, action.targetFrame?.isMainFrame == true,
           ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            decisionHandler(.cancel)
            Task { @MainActor [weak self] in self?.navigate(url.absoluteString) }
            return
        }
        // Do not silently hand arbitrary custom schemes to other applications.
        decisionHandler(["https", "http", "about"].contains(url.scheme?.lowercased() ?? "") ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if openCommandClickedLink(action) { return nil }
        if action.targetFrame == nil, let url = action.request.url,
           ["http", "https"].contains(url.scheme ?? "") {
            if let onNewLink { onNewLink(url.absoluteString, false, action.sourceFrame.isMainFrame) }
            else { onNewTab?(url.absoluteString) }
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        let alert = NSAlert(); alert.messageText = webView.url?.host ?? "Web page"; alert.informativeText = message
        alert.runModal(); completionHandler()
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        let alert = NSAlert(); alert.messageText = webView.url?.host ?? "Web page"; alert.informativeText = message
        alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
        let alert = NSAlert(); alert.messageText = prompt
        let field = NSTextField(string: defaultText ?? ""); field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field; alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
    }
}
