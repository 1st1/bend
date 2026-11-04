import AppKit
import Combine
import WebKit
import BrowseCore

@MainActor
final class BrowserStore: ObservableObject {
    @Published var session: BrowserSession
    @Published var sidebarVisible = true
    @Published var zoomedPane: UUID?
    var onAddressRequested: ((UUID) -> Void)?
    @Published var persistenceError: String?
    private var browsers: [UUID: PageController] = [:]
    private var pendingSave: Task<Void, Never>?
    private let sessionFile: URL

    init(sessionFile: URL? = nil) {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BrowsePrototype", isDirectory: true)
        self.sessionFile = sessionFile ?? root.appendingPathComponent("session.json")
        if let data = try? Data(contentsOf: self.sessionFile),
           let restored = try? JSONDecoder().decode(BrowserSession.self, from: data), restored.isValid {
            session = restored
        } else { session = BrowserSession() }
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
    func openPane(address: String, toRightOf source: UUID) {
        guard let tab = session.workspaces.flatMap(\.tabs).first(where: { $0.pages.contains { $0.id == source } }) else { return }
        select(tab.id)
        editTab(tab.id) { $0.split(axis: .horizontal, after: source, address: address) }
    }
    func resize(_ id: UUID, fraction: Double) { editTab { $0.layout = $0.layout.resizing(id, to: fraction) } }
    func toggleZoom(_ id: UUID) { focus(id); zoomedPane = zoomedPane == id ? nil : id }

    func newTab(in workspace: UUID? = nil, address: String = "browse://start") {
        let index = session.workspaces.firstIndex { $0.id == workspace }
            ?? session.workspaces.firstIndex { $0.tabs.contains { $0.id == session.selectedTab } } ?? 0
        let tab = BrowserTab(pages: [Page(address: address)])
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

    func closeTab(_ id: UUID) {
        for wi in session.workspaces.indices {
            guard let ti = session.workspaces[wi].tabs.firstIndex(where: { $0.id == id }) else { continue }
            for page in session.workspaces[wi].tabs[ti].pages { browsers.removeValue(forKey: page.id)?.webView.stopLoading() }
            session.workspaces[wi].tabs.remove(at: ti)
            let needsReplacement = session.workspaces[wi].tabs.isEmpty
            if needsReplacement { session.workspaces[wi].tabs.append(BrowserTab()) }
            if session.selectedTab == id { select(session.workspaces[wi].tabs[min(ti, session.workspaces[wi].tabs.count - 1)].id) }
            if needsReplacement && session.selectedTab == session.workspaces[wi].tabs[0].id { requestAddress() }
            saveSoon(); return
        }
    }

    func closePane(_ id: UUID) {
        if selectedTab.pages.count == 1 { closeTab(selectedTab.id); return }
        zoomedPane = nil; editTab { $0.closePane(id) }
        browsers.removeValue(forKey: id)?.webView.stopLoading()
    }

    func controller(for page: Page) -> PageController {
        if let existing = browsers[page.id] { return existing }
        let controller = PageController(address: page.address)
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
        controller.onFocus = { [weak self] in self?.focus(page.id) }
        browsers[page.id] = controller
        return controller
    }

    func saveSoon() {
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
    }
}

// @lat: [[architecture#WebKit integration]]
@MainActor
final class FocusWebView: WKWebView {
    var onFocus: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onFocus?(); super.mouseDown(with: event) }
    override func becomeFirstResponder() -> Bool { onFocus?(); return super.becomeFirstResponder() }
}

@MainActor
final class PageController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let webView: FocusWebView
    @Published var address: String
    @Published var title = "New tab"
    @Published var isLoading = false
    @Published var progress = 0.0
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var error: String?
    @Published var isStartPage = true
    var onNavigation: ((String, String) -> Void)?
    var onNewTab: ((String) -> Void)?
    var onNewPane: ((String) -> Void)?
    var onFocus: (() -> Void)?
    private var observations: [NSKeyValueObservation] = []
    private var lastReportedAddress = ""
    private var lastReportedTitle = ""

    init(address: String) {
        self.address = address
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = FocusWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self; webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = true
        webView.onFocus = { [weak self] in self?.onFocus?() }
        observations = [
            webView.observe(\.estimatedProgress) { [weak self] _, _ in Task { @MainActor in self?.refresh() } },
            webView.observe(\.isLoading) { [weak self] _, _ in Task { @MainActor in self?.refresh() } },
            webView.observe(\.title) { [weak self] _, _ in Task { @MainActor in self?.refresh() } }
        ]
        navigate(address)
    }

    func navigate(_ input: String) {
        guard let url = AddressResolver.resolve(input) else { error = "Enter a web address or search phrase."; return }
        error = nil; address = url.absoluteString
        isStartPage = url.scheme == "browse"
        if isStartPage {
            webView.stopLoading(); title = address == "browse://guide" ? "Tiling guide" : "New tab"
            reportNavigation()
        } else { webView.load(URLRequest(url: url)) }
    }

    func refresh() {
        isLoading = webView.isLoading; progress = webView.estimatedProgress
        canGoBack = webView.canGoBack; canGoForward = webView.canGoForward
        if !isStartPage {
            if let url = webView.url { address = url.absoluteString }
            title = webView.title?.isEmpty == false ? webView.title! : (webView.url?.host ?? "New tab")
            reportNavigation()
        }
    }

    private func reportNavigation() {
        guard address != lastReportedAddress || title != lastReportedTitle else { return }
        lastReportedAddress = address; lastReportedTitle = title
        onNavigation?(address, title)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { refresh() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { show(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { show(error) }
    func show(_ failure: Error) {
        if (failure as NSError).code != NSURLErrorCancelled { error = failure.localizedDescription }
        refresh()
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { error = "This page stopped responding. Reload to continue." }
    private func openCommandClickedLink(_ action: WKNavigationAction) -> Bool {
        guard action.navigationType == .linkActivated, action.modifierFlags.contains(.command),
              action.buttonNumber == 0, let url = action.request.url,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let onNewPane else { return false }
        onNewPane(url.absoluteString)
        return true
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if openCommandClickedLink(action) { decisionHandler(.cancel); return }
        // Do not silently hand arbitrary custom schemes to other applications.
        decisionHandler(["https", "http", "about"].contains(url.scheme?.lowercased() ?? "") ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if openCommandClickedLink(action) { return nil }
        if action.targetFrame == nil, let url = action.request.url,
           ["http", "https"].contains(url.scheme ?? "") { onNewTab?(url.absoluteString) }
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
