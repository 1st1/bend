import AppKit
import Combine
import WebKit
import BrowseCore
import WebKitFindSupport

@MainActor
final class BrowserStore: ObservableObject {
    @Published var session: BrowserSession {
        didSet { pruneChats(); sleepCoordinator?.noteVisible(previous: oldValue) }
    }
    @Published var chats: [UUID: TabChat] = [:]
    // Session observers can prune chats midway through a tab mutation. Only queue
    // persistence here; extension synchronization requires the completed layout.
    @Published var openChats: Set<UUID> = [] { didSet { if !windowStopped { scheduleSessionSave() } } }
    let tabReorderPreview = TabReorderPreview()
    let chatHistory: ChatHistoryStore

    func showChat() {
        guard !isPrivate else { return }
        let id = selectedTab.id
        if chats[id] == nil { chats[id] = TabChat(store: self, tabID: id) }
        openChats.insert(id)
    }

    private func pruneChats() {
        let ids = Set(session.workspaces.flatMap(\.tabs).map(\.id))
        for id in Array(chats.keys) where !ids.contains(id) {
            chats.removeValue(forKey: id)?.stop()
            openChats.remove(id)
        }
    }
    @Published var favoriteCustomization: FavoriteCustomizationRequest?
    @Published var sidebarVisible = true {
        didSet { if sidebarVisible { sidebarFloating = false } }
    }
    @Published var sidebarFloating = false
    @Published var isFullScreen = false
    @Published private(set) var zoomedPanes: [UUID: UUID] = [:] {
        didSet { if zoomedPanes != oldValue { scheduleSessionSave() } }
    }
    var zoomedPane: UUID? {
        get { zoomedPanes[session.selectedTab] }
        set { zoomedPanes[session.selectedTab] = newValue }
    }
    let mediaCoordinator = WindowMediaCoordinator()
    let mediaPlaybackFocus: MediaPlaybackFocus
    let downloads: BrowserDownloads
    @Published private(set) var paneMoveRevision = 0
    var onAddressRequested: ((UUID) -> Void)?
    var onCloseAllWindows: (() throws -> Void)?
    var onSettingsRequested: ((SettingsSection) -> Void)?
    var onEmptiedByTransfer: ((BrowserStore) -> Void)?
    var onNewWindowDrop: ((UUID, UUID?, NSPoint) -> Bool)?
    var onNewLinkWindow: ((String) -> Void)?
    private struct PendingAddressEntry {
        let tabID: UUID
        let paneID: UUID
        enum Kind {
            case tab(previousTabID: UUID)
            case pane(previousPaneID: UUID)
        }
        let kind: Kind
        let previousZoom: UUID?
    }
    private var pendingAddressEntry: PendingAddressEntry?
    private var extensionStorage: AnyObject?
    private let persistentExtensions: Bool
    @available(macOS 15.4, *)
    var extensions: ExtensionManager {
        if let manager = extensionStorage as? ExtensionManager { return manager }
        let manager = ExtensionManager(root: sessionFile.deletingLastPathComponent().appendingPathComponent("Extensions"), persistent: persistentExtensions)
        extensionStorage = manager
        manager.store = self
        manager.start()
        if persistentExtensions { manager.updates.start() }
        return manager
    }
    @Published var persistenceError: String?
    @Published private var localHistory = BrowsingHistory()
    @Published private var localHistoryError: String?
    let isPrivate: Bool
    private var privateWebsiteDataStore: WKWebsiteDataStore?
    private var windowStopped = false
    var historyOwner: BrowserStore { isPrivate ? self : (sharedStore?.historyOwner ?? self) }
    let sharedStore: BrowserStore?
    let websiteSettings: WebsiteSettingsStore
    let faviconCache: FaviconCache?
    private var faviconObservation: AnyCancellable?
    private var sharedObservation: AnyCancellable?
    var preferencesStore: BrowserStore { sharedStore?.preferencesStore ?? self }
    var historyPublisher: AnyPublisher<BrowsingHistory, Never> {
        isPrivate ? $localHistory.eraseToAnyPublisher() : (sharedStore?.historyPublisher ?? $localHistory.eraseToAnyPublisher())
    }
    private(set) var history: BrowsingHistory {
        get { isPrivate ? localHistory : (sharedStore?.history ?? localHistory) }
        set { localHistory = newValue }
    }
    private(set) var historyError: String? {
        get { isPrivate ? localHistoryError : (sharedStore?.historyError ?? localHistoryError) }
        set { localHistoryError = newValue }
    }
    private var browsers: [UUID: PageController] = [:]
    private(set) var sleepingPanes: [UUID: SleepingPane] = [:]
    let sleepPreferences: PaneSleepPreferences
    private var sleepObservation: AnyCancellable?
    private(set) var sleepCoordinator: PaneSleepCoordinator?
    private var diagnosticPaneTabs: [UUID: UUID] = [:]
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
    private let legacyHistoryFile: URL
    private var historyDatabase: HistoryDatabase?
    private(set) var historyLoad: Task<Void, Never>?
    private var startupHistoryEdits: [(inout BrowsingHistory) -> Void] = []
    private var resetHistoryOnLoadFailure = false
    private var pendingHistorySave: Task<Void, Never>?
    private var historyDirty = false
    private var historyWritable = true

    init(sessionFile: URL? = nil, persistentExtensions: Bool = true, extensionManager: AnyObject? = nil, sharedStore: BrowserStore? = nil, isPrivate: Bool = false, sleepPreferences: PaneSleepPreferences? = nil,
         historyQueue: DispatchQueue = .global(qos: .utility)) {
        self.sleepPreferences = sleepPreferences ?? sharedStore?.sleepPreferences ?? .shared
        self.isPrivate = isPrivate
        self.sharedStore = sharedStore
        mediaPlaybackFocus = sharedStore?.mediaPlaybackFocus ?? MediaPlaybackFocus()
        self.persistentExtensions = sharedStore?.persistentExtensions ?? persistentExtensions
        let root = AppProfile.current.supportDirectory
        self.sessionFile = sessionFile ?? root.appendingPathComponent("session.json")
        chatHistory = isPrivate ? ChatHistoryStore(directory: nil) : (sharedStore?.chatHistory ?? ChatHistoryStore(directory: self.sessionFile.deletingLastPathComponent().appendingPathComponent("AIChats")))
        faviconCache = isPrivate ? nil : (sharedStore?.faviconCache ?? FaviconCache(
            file: self.sessionFile.deletingLastPathComponent().appendingPathComponent("Favicons.json")))
        if isPrivate {
            downloads = BrowserDownloads(directory: sharedStore?.downloadDirectory ?? BrowserDownloads.defaultDirectory)
            websiteSettings = WebsiteSettingsStore(temporary: sharedStore?.websiteSettings.values ?? WebsiteSettings())
        } else {
            downloads = sharedStore?.downloads ?? BrowserDownloads(
                databaseFile: self.sessionFile.deletingLastPathComponent().appendingPathComponent("Downloads.db"))
            websiteSettings = sharedStore?.websiteSettings ?? WebsiteSettingsStore(
                file: self.sessionFile.deletingLastPathComponent().appendingPathComponent("WebsiteSettings.db"))
        }
        historyFile = self.sessionFile.deletingLastPathComponent().appendingPathComponent("History.db")
        legacyHistoryFile = self.sessionFile.deletingLastPathComponent().appendingPathComponent("history.json")
        if !isPrivate, let data = try? Data(contentsOf: self.sessionFile),
           let restored = try? JSONDecoder().decode(BrowserSession.self, from: data), restored.isValid {
            session = restored
            if let savedZoom = restored.zoomedPanes {
                for tab in restored.workspaces.flatMap(\.tabs) where tab.pages.count > 1 {
                    if let pane = savedZoom[tab.id], tab.pages.contains(where: { $0.id == pane }) {
                        zoomedPanes[tab.id] = pane
                    }
                }
            }
        } else { session = BrowserSession() }
        for wi in session.workspaces.indices {
            for ti in session.workspaces[wi].tabs.indices where session.workspaces[wi].tabs[ti].title == "New tab" {
                if let address = session.workspaces[wi].tabs[ti].pages.first?.address,
                   address != "bend://start", let title = AddressResolver.nativePageTitle(address) {
                    session.workspaces[wi].tabs[ti].title = title
                }
            }
        }
        if let favorites = session.favorites { session.favorites = SidebarFavorite.validated(favorites) }
        // Google account numbers in visited URLs depend on sign-in order. Restore
        // account-specific favorites through their saved email hint instead.
        let savedFavorites = sharedStore?.favorites ?? session.favorites ?? []
        for wi in session.workspaces.indices {
            for ti in session.workspaces[wi].tabs.indices {
                for pi in session.workspaces[wi].tabs[ti].pages.indices {
                    let id = session.workspaces[wi].tabs[ti].pages[pi].favoriteID
                    if let favorite = savedFavorites.first(where: { $0.id == id && $0.googleAccountEmail != nil }) {
                        session.workspaces[wi].tabs[ti].pages[pi].address = favorite.launchAddress
                    }
                }
            }
        }
        // Keep the persisted workspace envelope compatible, but expose one tab list.
        if session.workspaces.count > 1 {
            let tabs = session.workspaces.flatMap(\.tabs)
            session.workspaces = [session.workspaces[0]]
            session.workspaces[0].tabs = tabs
        }
        // Older sessions may retain the link-target role on a tab's only pane.
        for wi in session.workspaces.indices {
            for ti in session.workspaces[wi].tabs.indices where session.workspaces[wi].tabs[ti].pages.count == 1 {
                session.workspaces[wi].tabs[ti].commandClickPaneID = nil
            }
        }
        if sharedStore == nil && !isPrivate {
            historyLoad = Task { [weak self, historyFile, legacyHistoryFile] in
                guard let self else { return }
                do {
                    let database = try await Self.openHistory(file: historyFile, legacy: legacyHistoryFile, on: historyQueue)
                    self.finishHistoryLoad(database)
                } catch {
                    self.finishHistoryLoad(nil)
                }
            }
        }
        if !isPrivate {
            for tab in session.workspaces.flatMap(\.tabs) {
                if let id = session.activeChatIDs?[tab.id], let record = chatHistory.records.first(where: { $0.id == id }) {
                    let chat = TabChat(store: self, tabID: tab.id)
                    chat.restore(record); chats[tab.id] = chat
                }
                if session.openChatTabs?.contains(tab.id) == true {
                    if chats[tab.id] == nil { chats[tab.id] = TabChat(store: self, tabID: tab.id) }
                    openChats.insert(tab.id)
                }
            }
        }
        if sharedStore == nil { downloads.directory = downloadDirectory }
        tracePaneMembership()
        extensionStorage = extensionManager
        sleepObservation = self.sleepPreferences.$enabled.removeDuplicates().sink { [weak self] enabled in
            guard let self else { return }
            if enabled {
                sleepCoordinator = PaneSleepCoordinator(store: self)
                sleepCoordinator?.start()
            } else {
                sleepCoordinator?.stop()
                sleepCoordinator = nil
            }
            for controller in browsers.values { controller.setSleepTracking(enabled) }
        }
        faviconObservation = faviconCache?.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        if let sharedStore {
            sharedObservation = sharedStore.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
            if #available(macOS 15.4, *) { extensionStorage = sharedStore.extensions }
        }
        if sharedStore == nil, #available(macOS 15.4, *), let manager = extensionManager as? ExtensionManager {
            manager.store = self
            manager.start()
        }
    }

    var selectedTab: BrowserTab {
        let tabs = session.workspaces.flatMap(\.tabs)
        if let selected = tabs.first(where: { $0.id == session.selectedTab }) { return selected }
        if let first = tabs.first {
            session.selectedTab = first.id
            return first
        }
        let tab = BrowserTab()
        var repaired = session
        if repaired.workspaces.isEmpty { repaired.workspaces = [Workspace(name: "Tabs", tabs: [tab])] }
        else { repaired.workspaces[0].tabs.append(tab) }
        repaired.selectedTab = tab.id
        session = repaired
        return tab
    }

    func editTab(_ id: UUID? = nil, _ change: (inout BrowserTab) -> Void) {
        let target = id ?? session.selectedTab
        for wi in session.workspaces.indices {
            if let ti = session.workspaces[wi].tabs.firstIndex(where: { $0.id == target }) {
                change(&session.workspaces[wi].tabs[ti]); saveSoon(); return
            }
        }
    }

    // @lat: [[lat.md/architecture/settings#UI preferences]]
    var downloadDirectory: URL {
        get {
            if let sharedStore { return sharedStore.downloadDirectory }
            guard let path = session.downloadDirectory, path.hasPrefix("/") else { return BrowserDownloads.defaultDirectory }
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        set {
            if let sharedStore { sharedStore.downloadDirectory = newValue; return }
            guard newValue.isFileURL else { return }
            let directory = newValue.standardizedFileURL
            session.downloadDirectory = directory.path == BrowserDownloads.defaultDirectory.path ? nil : directory.path
            downloads.directory = directory
            saveSoon()
        }
    }

    var customSearchEngine: CustomSearchEngine? {
        get { sharedStore?.customSearchEngine ?? session.customSearchEngine }
        set {
            if let sharedStore { sharedStore.customSearchEngine = newValue; return }
            session.customSearchEngine = newValue
            saveSoon()
        }
    }

    var searchEngineName: String {
        searchEngine == .custom ? (customSearchEngine?.name ?? "Custom") : searchEngine.name
    }

    var searchEngine: SearchEngine {
        get { sharedStore?.searchEngine ?? session.searchEngine ?? .google }
        set {
            if let sharedStore { sharedStore.searchEngine = newValue; return }
            session.searchEngine = newValue
            saveSoon()
        }
    }

    var commandClickDestination: CommandClickDestination {
        get {
            sharedStore?.commandClickDestination ?? session.commandClickDestination
                ?? (session.commandClickOpensNewTab == true ? .newTab : .newPane)
        }
        set {
            if let sharedStore { sharedStore.commandClickDestination = newValue; return }
            session.commandClickDestination = newValue
            session.commandClickOpensNewTab = newValue == .newTab
            saveSoon()
        }
    }

    var commandShiftClickDestination: LinkOpenDestination {
        get { sharedStore?.commandShiftClickDestination ?? session.commandShiftClickDestination ?? .newTab }
        set {
            if let sharedStore { sharedStore.commandShiftClickDestination = newValue; return }
            session.commandShiftClickDestination = newValue
            saveSoon()
        }
    }

    var optionClickDestination: LinkOpenDestination {
        get { sharedStore?.optionClickDestination ?? session.optionClickDestination ?? .newTab }
        set {
            if let sharedStore { sharedStore.optionClickDestination = newValue; return }
            session.optionClickDestination = newValue
            saveSoon()
        }
    }

    var closeLinkTabOnBack: Bool {
        get { sharedStore?.closeLinkTabOnBack ?? session.closeLinkTabOnBack ?? true }
        set {
            if let sharedStore { sharedStore.closeLinkTabOnBack = newValue; return }
            session.closeLinkTabOnBack = newValue
            saveSoon()
        }
    }

    var closeLinkPaneOnBack: Bool {
        get { sharedStore?.closeLinkPaneOnBack ?? session.closeLinkPaneOnBack ?? true }
        set {
            if let sharedStore { sharedStore.closeLinkPaneOnBack = newValue; return }
            session.closeLinkPaneOnBack = newValue
            saveSoon()
        }
    }

    static let defaultInactivePaneDimAmount = 0.08

    var inactivePaneDimAmount: Double {
        get {
            if let sharedStore { return sharedStore.inactivePaneDimAmount }
            let amount = session.inactivePaneDimAmount ?? Self.defaultInactivePaneDimAmount
            return amount.isFinite ? min(1, max(0, amount)) : Self.defaultInactivePaneDimAmount
        }
        set {
            if let sharedStore { sharedStore.inactivePaneDimAmount = newValue; return }
            guard newValue.isFinite else { return }
            session.inactivePaneDimAmount = min(1, max(0, newValue))
            saveSoon()
        }
    }

    // @lat: [[lat.md/architecture/sidebar#Sidebar placement]]
    var sidebarSide: SidebarSide {
        get { sharedStore?.sidebarSide ?? session.sidebarSide ?? .left }
        set {
            if let sharedStore { sharedStore.sidebarSide = newValue; return }
            session.sidebarSide = newValue
            saveSoon()
        }
    }

    static let defaultSidebarWidth: CGFloat = 250
    static let sidebarWidthRange: ClosedRange<CGFloat> = 200...400

    static let defaultChatWidth: CGFloat = 360
    static let chatWidthRange = sidebarWidthRange.lowerBound...(sidebarWidthRange.upperBound * 1.5)
    var chatWidth: CGFloat {
        let width = session.chatWidth.map { CGFloat($0) } ?? Self.defaultChatWidth
        return width.isFinite ? min(Self.chatWidthRange.upperBound, max(Self.chatWidthRange.lowerBound, width)) : Self.defaultChatWidth
    }
    func resizeChat(to width: CGFloat) {
        guard width.isFinite else { return }
        let clamped = min(Self.chatWidthRange.upperBound, max(Self.chatWidthRange.lowerBound, width))
        guard clamped != chatWidth else { return }
        session.chatWidth = clamped
        scheduleSessionSave()
    }

    var sidebarWidth: CGFloat {
        let width = session.sidebarWidth.map { CGFloat($0) } ?? Self.defaultSidebarWidth
        return width.isFinite ? min(Self.sidebarWidthRange.upperBound, max(Self.sidebarWidthRange.lowerBound, width)) : Self.defaultSidebarWidth
    }

    var windowGlass: GlassAppearance {
        get { if let sharedStore { return sharedStore.windowGlass }; return (session.windowGlass ?? .windowDefault).normalized(defaultDarkening: GlassAppearance.windowDefault.darkening) }
        set { if let sharedStore { sharedStore.windowGlass = newValue; return }; session.windowGlass = newValue.normalized(defaultDarkening: GlassAppearance.windowDefault.darkening); saveSoon() }
    }

    var paneHeaderGlass: GlassAppearance {
        get { if let sharedStore { return sharedStore.paneHeaderGlass }; return (session.paneHeaderGlass ?? .headerDefault).normalized(defaultDarkening: 0.5) }
        set { if let sharedStore { sharedStore.paneHeaderGlass = newValue; return }; session.paneHeaderGlass = newValue.normalized(defaultDarkening: 0.5); saveSoon() }
    }

    static let defaultAIBubbleTransparency = 0.94
    var aiBubbleTransparency: Double {
        get {
            if let sharedStore { return sharedStore.aiBubbleTransparency }
            let value = session.aiBubbleTransparency ?? Self.defaultAIBubbleTransparency
            return value.isFinite ? min(1, max(0, value)) : Self.defaultAIBubbleTransparency
        }
        set {
            guard newValue.isFinite else { return }
            if let sharedStore { sharedStore.aiBubbleTransparency = newValue; return }
            session.aiBubbleTransparency = min(1, max(0, newValue))
            saveSoon()
        }
    }

    var floatingPanelGlass: GlassAppearance {
        get {
            if let sharedStore { return sharedStore.floatingPanelGlass }
            return (session.floatingPanelGlass ?? session.chatComposerGlass ?? session.mediaPlayerGlass ?? .floatingPanelDefault)
                .normalized(defaultDarkening: GlassAppearance.floatingPanelDefault.darkening)
        }
        set {
            if let sharedStore { sharedStore.floatingPanelGlass = newValue; return }
            var updated = session
            updated.floatingPanelGlass = newValue.normalized(defaultDarkening: GlassAppearance.floatingPanelDefault.darkening)
            updated.chatComposerGlass = nil
            updated.mediaPlayerGlass = nil
            session = updated
            saveSoon()
        }
    }

    static let defaultHeaderTopRimClipping: Double = 0.5
    static let defaultHeaderBottomRimClipping: Double = 1.1
    static let headerRimClippingRange: ClosedRange<Double> = 0...16

    var paneHeaderTopRimClipping: Double {
        get {
            if let sharedStore { return sharedStore.paneHeaderTopRimClipping }
            let value = session.paneHeaderTopRimClipping ?? Self.defaultHeaderTopRimClipping
            return value.isFinite ? min(Self.headerRimClippingRange.upperBound, max(0, value)) : Self.defaultHeaderTopRimClipping
        }
        set {
            if let sharedStore { sharedStore.paneHeaderTopRimClipping = newValue; return }
            guard newValue.isFinite else { return }
            session.paneHeaderTopRimClipping = min(Self.headerRimClippingRange.upperBound, max(0, newValue))
            saveSoon()
        }
    }

    var paneHeaderBottomRimClipping: Double {
        get {
            if let sharedStore { return sharedStore.paneHeaderBottomRimClipping }
            let value = session.paneHeaderBottomRimClipping ?? Self.defaultHeaderBottomRimClipping
            return value.isFinite ? min(Self.headerRimClippingRange.upperBound, max(0, value)) : Self.defaultHeaderBottomRimClipping
        }
        set {
            if let sharedStore { sharedStore.paneHeaderBottomRimClipping = newValue; return }
            guard newValue.isFinite else { return }
            session.paneHeaderBottomRimClipping = min(Self.headerRimClippingRange.upperBound, max(0, newValue))
            saveSoon()
        }
    }

    var paneHighlight: PaneHighlight {
        get { if let sharedStore { return sharedStore.paneHighlight }; return (session.paneHighlight ?? PaneHighlight()).normalized() }
        set { if let sharedStore { sharedStore.paneHighlight = newValue; return }; session.paneHighlight = newValue.normalized(); saveSoon() }
    }

    func resizeSidebar(to width: CGFloat) {
        guard width.isFinite else { return }
        let clamped = min(Self.sidebarWidthRange.upperBound, max(Self.sidebarWidthRange.lowerBound, width))
        guard clamped != sidebarWidth else { return }
        session.sidebarWidth = clamped
        saveSoon()
    }

    @discardableResult
    func reorderTab(_ source: UUID, relativeTo target: UUID, after: Bool) -> Bool {
        guard source != target,
              let wi = session.workspaces.firstIndex(where: { $0.tabs.contains { $0.id == source } }),
              let sourceIndex = session.workspaces[wi].tabs.firstIndex(where: { $0.id == source }),
              let targetIndex = session.workspaces[wi].tabs.firstIndex(where: { $0.id == target }) else { return false }
        var destination = targetIndex + (after ? 1 : 0)
        if sourceIndex < destination { destination -= 1 }
        guard sourceIndex != destination else { return false }
        var tabs = session.workspaces[wi].tabs
        let tab = tabs.remove(at: sourceIndex)
        tabs.insert(tab, at: destination)
        session.workspaces[wi].tabs = tabs
        saveSoon()
        return true
    }

    func select(_ id: UUID) {
        InputDiagnostics.transition(.storeSelection, session.selectedTab == id ? .unchanged : .changed, tabID: id)
        session.selectedTab = id; saveSoon()
    }
    private func linkTabToCloseOnBack(for pageID: UUID) -> BrowserTab? {
        guard closeLinkTabOnBack,
              let tab = session.workspaces.flatMap(\.tabs).first(where: { $0.pages.contains { $0.id == pageID } }),
              tab.originTabID != nil, tab.pages.count == 1, !tab.isPinned else { return nil }
        return tab
    }

    private func linkPaneToCloseOnBack(for pageID: UUID) -> Page? {
        guard closeLinkPaneOnBack,
              let tab = session.workspaces.flatMap(\.tabs).first(where: { $0.pages.contains { $0.id == pageID } }),
              tab.pages.count > 1, !tab.isPinned,
              let page = tab.pages.first(where: { $0.id == pageID }), !page.isPinned,
              page.originPageID != nil else { return nil }
        return page
    }

    private func canCloseOnBack(_ pageID: UUID) -> Bool {
        linkPaneToCloseOnBack(for: pageID) != nil || linkTabToCloseOnBack(for: pageID) != nil
    }

    private func closeOnBack(_ pageID: UUID) {
        if let page = linkPaneToCloseOnBack(for: pageID) {
            closePane(pageID)
            if let origin = page.originPageID { focus(origin) }
        } else if let tab = linkTabToCloseOnBack(for: pageID) {
            closeTab(tab.id)
        }
    }

    func canGoBack(from pageID: UUID) -> Bool {
        let controller = existingController(for: pageID)
        return (controller?.webView.canGoBack == true && controller?.backItemClosesPage != true) || canCloseOnBack(pageID)
    }

    // @lat: [[lat.md/architecture/link-navigation#Back from a link-created tab]]
    func goBack(from pageID: UUID) {
        guard let controller = existingController(for: pageID) else { return }
        if controller.backItemClosesPage {
            closeOnBack(pageID)
        } else if controller.webView.canGoBack {
            controller.webView.goBack()
        } else {
            closeOnBack(pageID)
        }
    }

    func focus(_ id: UUID) {
        InputDiagnostics.transition(.storeFocus, selectedTab.focusedPane == id ? .unchanged : .requested, paneID: id)
        guard selectedTab.focusedPane != id, selectedTab.pages.contains(where: { $0.id == id }) else { return }
        if let zoomedPane, zoomedPane != id { self.zoomedPane = nil }
        editTab { $0.focusedPane = id }
        InputDiagnostics.transition(.storeFocus, .changed, paneID: id)
    }
    func split(_ axis: SplitAxis) {
        let previousPaneID = selectedTab.focusedPane, previousZoom = zoomedPane
        zoomedPane = nil
        editTab { $0.split(axis: axis) }
        pendingAddressEntry = PendingAddressEntry(tabID: selectedTab.id, paneID: selectedTab.focusedPane,
            kind: .pane(previousPaneID: previousPaneID), previousZoom: previousZoom)
        requestAddress()
    }

    func requestAddress(for paneID: UUID? = nil) {
        let target = paneID ?? selectedTab.focusedPane
        InputDiagnostics.transition(.addressRequest, .requested, paneID: target)
        guard selectedTab.pages.contains(where: { $0.id == target }) else { return }
        focus(target)
        onAddressRequested?(target)
    }
    func openPane(address: String, toRightOf source: UUID, fromMainFrame: Bool = true) {
        guard let tab = session.workspaces.flatMap(\.tabs).first(where: { $0.pages.contains { $0.id == source } }) else { return }
        select(tab.id)
        zoomedPane = nil
        editTab(tab.id) {
            $0.split(axis: .horizontal, after: source, address: address)
            let destination = $0.focusedPane
            if let index = $0.pages.firstIndex(where: { $0.id == destination }) { $0.pages[index].originPageID = source }
            if fromMainFrame { linkOpeners[$0.focusedPane] = source }
        }
    }

    private func openInDedicatedPane(address: String, from source: UUID, fromMainFrame: Bool) {
        guard let tab = session.workspaces.flatMap(\.tabs).first(where: { $0.pages.contains { $0.id == source } }) else { return }
        guard let targetID = tab.commandClickPaneID, let page = tab.pages.first(where: { $0.id == targetID }) else {
            openPane(address: address, toRightOf: source, fromMainFrame: fromMainFrame)
            editTab(tab.id) { $0.commandClickPaneID = $0.focusedPane }
            return
        }
        select(tab.id)
        if let zoomedPane, zoomedPane != targetID { self.zoomedPane = nil }
        if fromMainFrame && source != targetID { linkOpeners[targetID] = source }
        else { linkOpeners[targetID] = nil }
        var destination = page
        destination.address = address
        editTab(tab.id) { tab in
            if let index = tab.pages.firstIndex(where: { $0.id == targetID }) { tab.pages[index] = destination }
            tab.focusedPane = targetID
        }
        if let controller = existingController(for: targetID) { controller.navigate(address) }
        else { _ = controller(for: destination) }
    }
    func resize(_ id: UUID, fraction: Double, geometry: PaneGeometry) {
        editTab { $0.layout = $0.layout.resizing(id, to: fraction, geometry: geometry) }
    }
    @discardableResult
    func movePane(_ source: UUID, beside target: UUID, edge: PaneDropEdge, in tabID: UUID, from sourceTabID: UUID? = nil) -> Bool {
        InputDiagnostics.transition(.paneMove, .requested, paneID: source, tabID: tabID, relatedPaneID: target)
        guard selectedTab.id == tabID, zoomedPane == nil else { return false }
        if let sourceTabID, sourceTabID != tabID {
            var next = session
            guard next.transferPane(source, from: sourceTabID, beside: target, in: tabID, edge: edge) else { return false }
            zoomedPanes[sourceTabID] = nil
            refreshTransferredTitles(&next)
            session = next
            saveSoon()
            InputDiagnostics.transition(.paneMove, .finished, paneID: source, tabID: session.selectedTab)
            paneMoveRevision += 1
            return true
        }
        guard let layout = selectedTab.layout.moving(source, beside: target, edge: edge) else { return false }
        editTab(tabID) { $0.layout = layout; $0.focusedPane = source }
        InputDiagnostics.transition(.paneMove, .finished, paneID: source, tabID: session.selectedTab)
        paneMoveRevision += 1
        return true
    }

    func separatePanes(_ ids: [UUID], from tabID: UUID) {
        guard let workspace = session.workspaces.first(where: { $0.tabs.contains { $0.id == tabID } }) else { return }
        var next = session
        var firstDestination: UUID?
        for id in ids {
            let title = browsers[id]?.title ?? "New tab"
            if let destination = next.detachPane(id, from: tabID, into: workspace.id, title: title) {
                if firstDestination == nil { firstDestination = destination }
            }
        }
        guard let firstDestination else { return }
        next.selectedTab = firstDestination
        refreshTransferredTitles(&next)
        zoomedPanes[tabID] = nil
        session = next
        paneMoveRevision += 1
        saveSoon()
    }

    @discardableResult
    func detachPane(_ source: UUID, from sourceTabID: UUID, into workspaceID: UUID) -> Bool {
        var next = session
        let title = browsers[source]?.title ?? session.workspaces.flatMap(\.tabs)
            .first(where: { $0.id == sourceTabID })?.title ?? "New tab"
        guard next.detachPane(source, from: sourceTabID, into: workspaceID, title: title) != nil else { return false }
        zoomedPanes[sourceTabID] = nil
        refreshTransferredTitles(&next)
        session = next
        saveSoon()
        InputDiagnostics.transition(.paneMove, .finished, paneID: source, tabID: session.selectedTab)
        paneMoveRevision += 1
        return true
    }

    @discardableResult
    func movePaneToTab(_ source: UUID, from sourceTabID: UUID, into destinationID: UUID) -> Bool {
        InputDiagnostics.transition(.paneMove, .requested, paneID: source, tabID: destinationID)
        var next = session
        guard let destination = next.workspaces.flatMap(\.tabs).first(where: { $0.id == destinationID }),
              next.transferPane(source, from: sourceTabID, beside: destination.focusedPane,
                                in: destinationID, edge: .right) else { return false }
        zoomedPanes[sourceTabID] = nil
        zoomedPanes[destinationID] = nil
        refreshTransferredTitles(&next)
        session = next
        saveSoon()
        InputDiagnostics.transition(.paneMove, .finished, paneID: source, tabID: destinationID)
        paneMoveRevision += 1
        return true
    }

    @discardableResult
    func joinTabs(_ sourceID: UUID, into destinationID: UUID,
                  beside target: UUID? = nil, edge: PaneDropEdge = .right) -> Bool {
        InputDiagnostics.transition(.tabDrop, .requested, tabID: destinationID, flags: ["join": true])
        let panes = session.workspaces.flatMap(\.tabs).first(where: { $0.id == sourceID })?.pages ?? []
        var next = session
        guard next.joinTabs(sourceID, into: destinationID, beside: target, edge: edge) else { return false }
        zoomedPanes[sourceID] = nil
        zoomedPanes[destinationID] = nil
        session = next
        saveSoon()
        for pane in panes {
            InputDiagnostics.transition(.paneMove, .finished, paneID: pane.id, tabID: destinationID)
        }
        InputDiagnostics.transition(.tabDrop, .finished, tabID: destinationID, flags: ["join": true])
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
    func toggleZoom(_ id: UUID) {
        InputDiagnostics.transition(.storeZoom, .changed, paneID: id, flags: ["zooming": zoomedPane != id])
        focus(id); zoomedPane = zoomedPane == id ? nil : id
    }

    func newTab(in workspace: UUID? = nil, address: String = "bend://start", linkOpener: UUID? = nil, originPageID: UUID? = nil,
                closeIfDownload: Bool = false, afterCurrent: Bool = false, inBackground: Bool = false) {
        let address = AddressResolver.canonicalAddress(address)
        let previousTabID = session.selectedTab
        let index = session.workspaces.firstIndex { $0.id == workspace }
            ?? session.workspaces.firstIndex { $0.tabs.contains { $0.id == session.selectedTab } } ?? 0
        let title = address == "bend://start" ? "New tab" : AddressResolver.nativePageTitle(address) ?? "New tab"
        var tab = BrowserTab(title: title, pages: [Page(address: address)])
        if let source = originPageID ?? linkOpener {
            tab.pages[0].originPageID = source
            tab.originTabID = session.workspaces.flatMap(\.tabs).first { $0.pages.contains { $0.id == source } }?.id
        }
        if let linkOpener { linkOpeners[tab.pages[0].id] = linkOpener }
        let insertion = afterCurrent ? session.workspaces[index].tabs.firstIndex { $0.id == previousTabID }.map { $0 + 1 } : nil
        session.workspaces[index].tabs.insert(tab, at: insertion ?? session.workspaces[index].tabs.count)
        if inBackground {
            saveSoon()
        } else {
            select(tab.id)
            pendingAddressEntry = address == "bend://start" ? PendingAddressEntry(tabID: tab.id, paneID: tab.pages[0].id,
                kind: .tab(previousTabID: previousTabID), previousZoom: nil) : nil
            if address == "bend://start" { requestAddress() }
        }
        // Background tabs have no mounted view yet, but should start loading now.
        if inBackground { _ = controller(for: tab.pages[0]) }
        if closeIfDownload {
            controller(for: tab.pages[0]).onInitialDownload = { [weak self] in
                self?.discardDownloadTab(tab.id, paneID: tab.pages[0].id, previousTabID: previousTabID)
            }
        }
    }

    func duplicateTab(_ id: UUID) {
        guard let wi = session.workspaces.firstIndex(where: { $0.tabs.contains { $0.id == id } }),
              let ti = session.workspaces[wi].tabs.firstIndex(where: { $0.id == id }) else { return }
        let source = session.workspaces[wi].tabs[ti]
        guard source.hasValidLayout else { return }
        let pages = source.pages.map { Page(address: existingController(for: $0.id)?.address ?? $0.address) }
        let ids = Dictionary(uniqueKeysWithValues: zip(source.pages.map(\.id), pages.map(\.id)))
        guard let layout = source.layout.remappingPanes(ids),
              let focus = ids[source.focusedPane] else { return }
        var tab = BrowserTab(title: source.title, pages: pages)
        tab.layout = layout
        tab.focusedPane = focus
        tab.commandClickPaneID = source.commandClickPaneID.flatMap { ids[$0] }
        session.workspaces[wi].tabs.insert(tab, at: ti + 1)
        pendingAddressEntry = nil
        select(tab.id)
    }

    private func discardDownloadTab(_ tabID: UUID, paneID: UUID, previousTabID: UUID) {
        guard let wi = session.workspaces.firstIndex(where: { $0.tabs.contains { $0.id == tabID } }),
              let ti = session.workspaces[wi].tabs.firstIndex(where: { $0.id == tabID }),
              session.workspaces[wi].tabs[ti].pages.map(\.id) == [paneID],
              !session.workspaces[wi].tabs[ti].isPinned,
              session.workspaces[wi].tabs.count > 1 else { return }
        zoomedPanes[tabID] = nil
        removeController(paneID)
        session.workspaces[wi].tabs.remove(at: ti)
        if session.selectedTab == tabID {
            let previous = session.workspaces.flatMap(\.tabs).first { $0.id == previousTabID }
            select(previous?.id ?? session.workspaces[wi].tabs[min(ti, session.workspaces[wi].tabs.count - 1)].id)
        }
        // This tab never displayed a document; it must not enter closed-tab history.
        saveSoon()
    }

    func finishInitialAddressEntry(for paneID: UUID) {
        if pendingAddressEntry?.paneID == paneID { pendingAddressEntry = nil }
    }

    @discardableResult
    func cancelInitialAddressEntry(for paneID: UUID) -> Bool {
        guard let pending = pendingAddressEntry, pending.paneID == paneID,
              session.selectedTab == pending.tabID,
              let wi = session.workspaces.firstIndex(where: { $0.tabs.contains { $0.id == pending.tabID } }),
              let ti = session.workspaces[wi].tabs.firstIndex(where: { $0.id == pending.tabID }) else { return false }
        let tab = session.workspaces[wi].tabs[ti]
        guard let page = tab.pages.first(where: { $0.id == paneID }), !page.isPinned, page.address == "bend://start",
              (browsers[paneID]?.address ?? "bend://start") == "bend://start" else { return false }
        switch pending.kind {
        case .tab:
            guard tab.pages.count == 1, session.workspaces[wi].tabs.count > 1 else { return false }
        case .pane:
            guard tab.pages.count > 1 else { return false }
        }
        pendingAddressEntry = nil
        removeController(paneID)
        switch pending.kind {
        case .tab(let previousTabID):
            zoomedPanes[tab.id] = nil
            session.workspaces[wi].tabs.remove(at: ti)
            let previous = session.workspaces.flatMap(\.tabs).first { $0.id == previousTabID }
            select(previous?.id ?? session.workspaces[wi].tabs[min(ti, session.workspaces[wi].tabs.count - 1)].id)
        case .pane(let previousPaneID):
            editTab(tab.id) {
                $0.closePane(paneID)
                if $0.pages.contains(where: { $0.id == previousPaneID }) { $0.focusedPane = previousPaneID }
            }
        }
        if let zoom = pending.previousZoom, selectedTab.pages.contains(where: { $0.id == zoom }) {
            zoomedPane = zoom
        }
        InputDiagnostics.transition(.addressCancel, .finished, paneID: paneID, tabID: pending.tabID,
            flags: ["discardNewTab": tab.pages.count == 1, "discardNewPane": tab.pages.count > 1])
        return true
    }

    func showChangelog() {
        for workspace in session.workspaces {
            if let tab = workspace.tabs.first(where: { $0.pages.contains { $0.address == "bend://log" } }),
               let page = tab.pages.first(where: { $0.address == "bend://log" }) {
                select(tab.id); focus(page.id); return
            }
        }
        newTab(address: "bend://log")
    }

    func showHistory() {
        for workspace in session.workspaces {
            if let tab = workspace.tabs.first(where: { $0.pages.contains { $0.address == "bend://history" } }),
               let page = tab.pages.first(where: { $0.address == "bend://history" }) {
                select(tab.id); focus(page.id); return
            }
        }
        newTab(address: "bend://history")
    }

    // Opening SQLite also restores visits and prepares the suggestion index.
    // Transfer the finished connection to the main actor for subsequent saves.
    private static func openHistory(file: URL, legacy: URL, on queue: DispatchQueue) async throws -> sending HistoryDatabase {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try HistoryDatabase(file: file, legacyFile: legacy)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func finishHistoryLoad(_ database: HistoryDatabase?) {
        historyLoad = nil
        historyDatabase = database
        if let database {
            var restored = database.load()
            for edit in startupHistoryEdits { edit(&restored) }
            history = restored
        } else {
            historyWritable = false
            historyError = "Saved history could not be read. Clear history to reset it."
            if resetHistoryOnLoadFailure { resetUnreadableHistory() }
        }
        startupHistoryEdits.removeAll()
        resetHistoryOnLoadFailure = false
        saveHistory()
    }

    private func editHistory<Value>(_ edit: @escaping (inout BrowsingHistory) -> Value) -> Value {
        if historyLoad != nil { startupHistoryEdits.append { _ = edit(&$0) } }
        return edit(&history)
    }

    func recordVisit(url: String, title: String, at date: Date = Date()) {
        if historyOwner !== self { historyOwner.recordVisit(url: url, title: title, at: date); return }
        guard !isPrivate || !windowStopped else { return }
        let recorded = editHistory { $0.record(url: url, title: title, at: date) }
        if recorded { saveHistorySoon() }
    }

    func recordHistoryChoice(url: String, query: String) {
        guard !isPrivate || !windowStopped else { return }
        if historyOwner !== self { historyOwner.recordHistoryChoice(url: url, query: query); return }
        let date = Date()
        editHistory { $0.recordChoice(url: url, query: query, at: date) }
        saveHistorySoon()
    }

    func removeHistory(url: String) {
        if historyOwner !== self { historyOwner.removeHistory(url: url); return }
        editHistory { $0.remove(url: url) }
        historyDirty = true
        saveHistory()
    }

    func clearHistory(since cutoff: Date) {
        if historyOwner !== self { historyOwner.clearHistory(since: cutoff); return }
        if cutoff == .distantPast { clearHistory(); return }
        guard historyWritable else { historyError = "Saved history cannot be read. Choose All to reset it."; return }
        editHistory { $0.clear(since: cutoff) }
        historyDirty = true; saveHistory()
    }

    func clearHistory() {
        if historyOwner !== self { historyOwner.clearHistory(); return }
        faviconCache?.clear()
        if historyLoad != nil {
            startupHistoryEdits.removeAll()
            resetHistoryOnLoadFailure = true
        }
        editHistory { $0.clear() }
        if !historyWritable { resetUnreadableHistory() }
        historyDirty = true
        saveHistory()
    }

    private func resetUnreadableHistory() {
        do {
            historyDatabase = nil
            // Explicit Clear History is the only operation allowed to discard unreadable storage.
            for file in [legacyHistoryFile, historyFile,
                         URL(fileURLWithPath: historyFile.path + "-wal"),
                         URL(fileURLWithPath: historyFile.path + "-shm")] {
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            }
            historyDatabase = try HistoryDatabase(file: historyFile)
            historyWritable = true
        } catch {
            historyError = "History could not be cleared: \(error.localizedDescription)"
            return
        }
    }

    private func saveHistorySoon() {
        guard !isPrivate else { return }
        historyDirty = true
        pendingHistorySave?.cancel()
        pendingHistorySave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            self?.saveHistory()
        }
    }

    func saveHistory() {
        guard !isPrivate else { return }
        if historyOwner !== self { historyOwner.saveHistory(); return }
        pendingHistorySave?.cancel()
        pendingHistorySave = nil
        guard historyDirty, historyWritable else { return }
        do {
            guard let historyDatabase else { return }
            try historyDatabase.save(history)
            historyDirty = false
            historyError = nil
        } catch { historyError = "History could not be saved: \(error.localizedDescription)" }
    }

    // @lat: [[lat.md/architecture/pane-controls#Pinned panes and tabs]]
    func isPanePinned(_ id: UUID) -> Bool {
        session.workspaces.flatMap(\.tabs).flatMap(\.pages).first { $0.id == id }?.isPinned == true
    }

    func setPanePinned(_ id: UUID, pinned: Bool) {
        guard let tab = session.workspaces.flatMap(\.tabs).first(where: { $0.pages.contains { $0.id == id } }) else { return }
        editTab(tab.id) { tab in
            if let index = tab.pages.firstIndex(where: { $0.id == id }) {
                if pinned && !tab.pages[index].isPinned {
                    tab.pages[index].pinnedAddress = existingController(for: id)?.address ?? tab.pages[index].address
                } else if !pinned { tab.pages[index].pinnedAddress = nil }
                tab.pages[index].isPinned = pinned
            }
        }
    }

    func setTabPinned(_ id: UUID, pinned: Bool) {
        guard let tab = session.workspaces.flatMap(\.tabs).first(where: { $0.id == id }) else { return }
        for page in tab.pages { setPanePinned(page.id, pinned: pinned) }
    }

    func pinnedReturnAddress(_ id: UUID) -> String? {
        guard let page = session.workspaces.flatMap(\.tabs).flatMap(\.pages).first(where: { $0.id == id }),
              page.isPinned, let address = page.pinnedAddress,
              (existingController(for: id)?.address ?? page.address) != address else { return nil }
        return address
    }

    func returnToPinnedURL(_ id: UUID) {
        guard let address = pinnedReturnAddress(id),
              let page = selectedTab.pages.first(where: { $0.id == id }) else { return }
        focus(id)
        // Return within this pane, including favorite panes; do not redirect into a new tab.
        controller(for: page).navigate(address)
    }

    func toggleTabPinned(_ id: UUID) {
        guard let tab = session.workspaces.flatMap(\.tabs).first(where: { $0.id == id }) else { return }
        setTabPinned(id, pinned: !tab.isPinned)
    }

    func closeTab(_ id: UUID) {
        guard session.workspaces.flatMap(\.tabs).first(where: { $0.id == id })?.isPinned == false else { return }
        zoomedPanes[id] = nil
        if pendingAddressEntry?.tabID == id { pendingAddressEntry = nil }
        for wi in session.workspaces.indices {
            guard let ti = session.workspaces[wi].tabs.firstIndex(where: { $0.id == id }) else { continue }
            let closed = snapshot(session.workspaces[wi].tabs[ti])
            for page in session.workspaces[wi].tabs[ti].pages { removeController(page.id) }
            session.workspaces[wi].tabs.remove(at: ti)
            let needsReplacement = session.workspaces[wi].tabs.isEmpty
            if needsReplacement { session.workspaces[wi].tabs.append(BrowserTab()) }
            rememberClosed(.init(tab: closed, workspaceID: session.workspaces[wi].id, tabIndex: ti, paneID: nil,
                replacementID: needsReplacement ? session.workspaces[wi].tabs[0].id : nil))
            if session.selectedTab == id {
                let origin = closed.originTabID.flatMap { origin in
                    session.workspaces.flatMap(\.tabs).first { $0.id == origin }?.id
                }
                select(origin ?? session.workspaces[wi].tabs[min(ti, session.workspaces[wi].tabs.count - 1)].id)
            }
            if needsReplacement && session.selectedTab == session.workspaces[wi].tabs[0].id { requestAddress() }
            saveSoon(); return
        }
    }

    func closePane(_ id: UUID) {
        guard selectedTab.pages.contains(where: { $0.id == id }) else { return }
        closePage(id)
    }

    func snapshot(_ tab: BrowserTab) -> BrowserTab {
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

    // @lat: [[lat.md/architecture/session#Reopening closed panes and tabs]]
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
                if tab.commandClickPaneID == nil, item.tab.commandClickPaneID == paneID { tab.commandClickPaneID = paneID }
                session.workspaces[wi].tabs[ti] = tab
            } else {
                var tab = BrowserTab(title: item.tab.title, pages: [page])
                tab.id = item.tab.id
                if item.tab.commandClickPaneID == paneID { tab.commandClickPaneID = paneID }
                session.workspaces[wi].tabs.insert(tab, at: min(item.tabIndex, session.workspaces[wi].tabs.count))
            }
        } else {
            if let replacementID = item.replacementID,
               let index = session.workspaces[wi].tabs.firstIndex(where: { $0.id == replacementID }) {
                let replacement = session.workspaces[wi].tabs[index]
                if !replacement.isPinned, replacement.pages.count == 1, replacement.pages[0].address == "bend://start",
                   (browsers[replacement.pages[0].id]?.address ?? "bend://start") == "bend://start" {
                    removeController(replacement.pages[0].id)
                    session.workspaces[wi].tabs.remove(at: index)
                }
            }
            session.workspaces[wi].tabs.insert(item.tab, at: min(item.tabIndex, session.workspaces[wi].tabs.count))
        }
        select(item.tab.id)
        zoomedPane = nil
    }

    // @lat: [[lat.md/architecture/privacy#Private windows]]
    var websiteDataStore: WKWebsiteDataStore {
        guard isPrivate else { return AppProfile.current.websiteDataStore }
        if let existing = privateWebsiteDataStore { return existing }
        let store = WKWebsiteDataStore.nonPersistent()
        privateWebsiteDataStore = store
        return store
    }

    func configureWebView(_ configuration: WKWebViewConfiguration) {
        if #available(macOS 15.4, *) { extensions.configure(configuration) }
        if isPrivate { configuration.websiteDataStore = websiteDataStore }
    }

    @available(macOS 15.4, *)
    func extensionConfiguration(for context: WKWebExtensionContext) -> WKWebViewConfiguration? {
        // The shared extension configuration also gives HTTP frames and requests
        // access to regular website cookies. WebKit's related extension views
        // require that store, so private panes cannot host extension documents.
        guard !isPrivate else { return nil }
        return context.webViewConfiguration
    }

    func controller(for page: Page) -> PageController {
        if let existing = browsers[page.id] { return existing }
        let extensionURL = URL(string: page.address).flatMap {
            ["webkit-extension", "safari-web-extension"].contains($0.scheme ?? "") ? $0 : nil
        }
        let sleeping = sleepingPanes.removeValue(forKey: page.id).flatMap { $0.address == page.address ? $0 : nil }
        let hasLinkOrigin = session.workspaces.flatMap(\.tabs).contains { $0.originTabID != nil && $0.pages.contains { $0.id == page.id } }
        let controller = PageController(address: extensionURL == nil ? page.address : "bend://start", paneID: page.id, isPrivate: isPrivate, websiteSettings: websiteSettings, faviconCache: faviconCache, seedCloseHistory: hasLinkOrigin || page.originPageID != nil, downloads: downloads, searchEngine: searchEngine, customSearchEngine: customSearchEngine, sleeping: sleeping, trackSleep: sleepPreferences.enabled, configure: { [weak self] configuration in
            self?.configureWebView(configuration)
        })
        bindController(controller, to: page)
        browsers[page.id] = controller
        sleepCoordinator?.didCreate(page.id)
        if isPrivate, extensionURL != nil {
            controller.error = PageController.privateExtensionPageError
            return controller
        }
        if #available(macOS 15.4, *), let extensionURL {
            let manager = extensions
            Task { [weak controller] in
                await manager.restorationTask?.value
                guard let controller, manager.store(for: page.id)?.existingController(for: page.id) === controller,
                      controller.address == "bend://start" else { return }
                let extensionURL = manager.restoredExtensionURL(extensionURL)
                guard let context = manager.controller.extensionContext(for: extensionURL), context.isLoaded,
                      let configuration = manager.store(for: page.id)?.extensionConfiguration(for: context) else {
                    controller.error = "This extension page is unavailable. Enable its extension in Settings."
                    return
                }
                controller.navigateExtension(extensionURL, configuration: configuration)
            }
        }
        return controller
    }

    // @lat: [[lat.md/architecture/pane-sleep#Automatic pane sleeping]]
    func sleepCandidate(_ id: UUID) -> PageController? {
        guard !windowStopped, sleepPreferences.enabled,
              websiteSettings.errorMessage == nil,
              let tab = session.workspaces.flatMap(\.tabs).first(where: { $0.pages.contains { $0.id == id } }),
              tab.id != session.selectedTab, chats[tab.id]?.running != true, !tab.isPinned,
              let page = tab.pages.first(where: { $0.id == id }), !page.isPinned, page.favoriteID == nil,
              !linkOpeners.keys.contains(id), !linkOpeners.values.contains(id),
              let controller = browsers[id], controller.canSleep,
              let url = controller.webView.url, let host = WebsiteSettings.hostname(for: url),
              !sleepPreferences.keepsAwake(host) else { return nil }
        return controller
    }

    func finishSleeping(_ id: UUID, controller: PageController, state: SleepingPane) {
        guard sleepCandidate(id) === controller else { return }
        controller.prepareForSleep()
        mediaCoordinator.unregister(id)
        browsers.removeValue(forKey: id)
        sleepingPanes[id] = state
        objectWillChange.send()
    }

    func favicon(for page: Page) -> NSImage? {
        let controller = existingController(for: page.id)
        guard controller?.isStartPage != true else { return nil }
        return controller?.favicon ?? faviconCache?.image(for: URL(string: controller?.address ?? page.address))
    }

    private func bindController(_ controller: PageController, to page: Page) {
        controller.searchEngine = { [weak self] in self?.searchEngine ?? .google }
        controller.customSearchEngine = { [weak self] in self?.customSearchEngine }
        controller.onFaviconChanged = { [weak self] in
            self?.objectWillChange.send()
            self?.refreshFavoriteIcon(for: page.id)
        }
        mediaPlaybackFocus.register(controller.media)
        mediaCoordinator.register(page.id, controller: controller.media)
        controller.configure = { [weak self] configuration in
            self?.configureWebView(configuration)
        }
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
        controller.canCloseFromHistory = { [weak self] in
            guard let self else { return false }
            return self.selectedTab.pages.contains { $0.id == page.id } && self.canCloseOnBack(page.id)
        }
        controller.onCloseFromHistory = { [weak self] in
            self?.closeOnBack(page.id)
        }
        controller.onNewTab = { [weak self] address in self?.newTab(address: address, originPageID: page.id, afterCurrent: true, inBackground: true) }
        controller.onNewPane = { [weak self] address in self?.openPane(address: address, toRightOf: page.id) }
        controller.onNewLink = { [weak self] address, adjacent, mainFrame in
            guard let self else { return }
            switch adjacent ? self.commandClickDestination : .newTab {
            case .newPane: self.openPane(address: address, toRightOf: page.id, fromMainFrame: mainFrame)
            case .dedicatedPane: self.openInDedicatedPane(address: address, from: page.id, fromMainFrame: mainFrame)
            case .newTab: self.newTab(address: address, linkOpener: mainFrame ? page.id : nil, originPageID: page.id, closeIfDownload: true, afterCurrent: true, inBackground: adjacent)
            }
        }
        controller.onCommandShiftLink = { [weak self] address, mainFrame in
            guard let self else { return }
            self.openLink(address, from: page.id, mainFrame: mainFrame, destination: self.commandShiftClickDestination)
        }
        controller.onOptionLink = { [weak self] address, mainFrame in
            guard let self else { return }
            self.openLink(address, from: page.id, mainFrame: mainFrame, destination: self.optionClickDestination)
        }
        controller.onOpenLink = { [weak self] address, mainFrame, destination in
            self?.openLink(address, from: page.id, mainFrame: mainFrame, destination: destination)
        }
        controller.onFocus = { [weak self] in self?.focus(page.id) }
        controller.onVisit = { [weak self] url, title in self?.recordVisit(url: url, title: title) }
        controller.onHistoryTitleChanged = { [weak self] url, title in
            guard let self, !self.isPrivate || !self.windowStopped else { return }
            let owner = self.historyOwner
            owner.editHistory { $0.updateTitle(title, for: url) }
            owner.saveHistorySoon()
        }
    }

    private func openLink(_ address: String, from pageID: UUID, mainFrame: Bool, destination: LinkOpenDestination) {
        switch destination {
        case .newTab:
            newTab(address: address, linkOpener: mainFrame ? pageID : nil, originPageID: pageID, closeIfDownload: true, afterCurrent: true,
                   inBackground: true)
        case .newPane:
            openPane(address: address, toRightOf: pageID, fromMainFrame: mainFrame)
        case .newWindow:
            onNewLinkWindow?(address)
        }
    }

    func existingController(for pageID: UUID) -> PageController? { browsers[pageID] }

    private func removeController(_ id: UUID) {
        sleepingPanes.removeValue(forKey: id)
        mediaCoordinator.unregister(id)
        let controller = browsers.removeValue(forKey: id)
        controller?.permissionPrompt.cancel()
        controller?.certificates.cancel()
        controller?.fileUpload.cancel()
        controller?.stopCapture()
        controller?.webView.closeInspector()
        controller?.media.detach()
        controller?.webView.pauseAllMediaPlayback(completionHandler: nil)
        controller?.webView.stopLoading()
    }

    // @lat: [[lat.md/architecture/pane-transfers#Cross-window dragging]]
    @discardableResult
    func transfer(tab tabID: UUID, pane paneID: UUID? = nil, to destination: BrowserStore,
                  at placement: WindowDropPlacement) -> Bool {
        guard self !== destination, !isPrivate, !destination.isPrivate, preferencesStore === destination.preferencesStore,
              let wi = session.workspaces.firstIndex(where: { $0.tabs.contains { $0.id == tabID } }),
              let ti = session.workspaces[wi].tabs.firstIndex(where: { $0.id == tabID }) else { return false }
        let original = session.workspaces[wi].tabs[ti]
        let emptiesWindow = session.workspaces.flatMap(\.tabs).count == 1
            && (paneID == nil || original.pages.count == 1)
        var incoming = snapshot(original)
        if let paneID {
            guard let page = incoming.pages.first(where: { $0.id == paneID }) else { return false }
            incoming = BrowserTab(title: browsers[paneID]?.title ?? incoming.title, pages: [page])
        }
        let movedIDs = Set(incoming.pages.map(\.id))
        guard !destination.session.workspaces.flatMap(\.tabs).contains(where: {
            $0.id == incoming.id || $0.pages.contains { movedIDs.contains($0.id) }
        }) else { return false }
        var nextSource = session, nextDestination = destination.session
        var replacedPages: [UUID] = []
        // Build and validate both layouts before changing ownership or views.
        switch placement {
        case .insert(let relativeID, let after):
            guard let dw = nextDestination.workspaces.firstIndex(where: { $0.tabs.contains { $0.id == relativeID } }),
                  let dt = nextDestination.workspaces[dw].tabs.firstIndex(where: { $0.id == relativeID }) else { return false }
            nextDestination.workspaces[dw].tabs.insert(incoming, at: dt + (after ? 1 : 0))
            nextDestination.selectedTab = incoming.id
        case .emptyWindow:
            guard nextDestination.workspaces.count == 1, nextDestination.workspaces[0].tabs.count == 1,
                  let blank = nextDestination.workspaces[0].tabs.first, !blank.isPinned,
                  blank.pages.count == 1, blank.pages[0].address == "bend://start",
                  (destination.browsers[blank.pages[0].id]?.address ?? "bend://start") == "bend://start" else { return false }
            replacedPages = blank.pages.map(\.id)
            nextDestination.workspaces[0].tabs = [incoming]
            nextDestination.selectedTab = incoming.id
        case .workspace(let id):
            guard let dw = nextDestination.workspaces.firstIndex(where: { $0.id == id }) else { return false }
            nextDestination.workspaces[dw].tabs.append(incoming)
            nextDestination.selectedTab = incoming.id
        case .join(let targetTab, let targetPane, let edge):
            guard let dw = nextDestination.workspaces.firstIndex(where: { $0.tabs.contains { $0.id == targetTab } }) else { return false }
            nextDestination.workspaces[dw].tabs.append(incoming)
            guard nextDestination.joinTabs(incoming.id, into: targetTab, beside: targetPane, edge: edge) else { return false }
        }
        if let paneID, original.pages.count > 1 {
            nextSource.workspaces[wi].tabs[ti].removePaneForTransfer(paneID)
        } else {
            nextSource.workspaces[wi].tabs.remove(at: ti)
            if nextSource.workspaces[wi].tabs.isEmpty { nextSource.workspaces[wi].tabs.append(BrowserTab()) }
            if nextSource.selectedTab == tabID {
                nextSource.selectedTab = nextSource.workspaces[wi].tabs[min(ti, nextSource.workspaces[wi].tabs.count - 1)].id
            }
        }
        guard nextSource.isValid, nextDestination.isValid else { return false }
        let oldPageOrder = session.workspaces.flatMap(\.tabs).flatMap(\.pages).map(\.id)
        for page in incoming.pages {
            if let sleeping = sleepingPanes.removeValue(forKey: page.id) {
                destination.sleepingPanes[page.id] = sleeping
            }
            destination.sleepCoordinator?.didCreate(page.id)
            if let controller = browsers[page.id] {
                destination.browsers[page.id] = controller
                destination.bindController(controller, to: page)
            }
            if let opener = linkOpeners[page.id], movedIDs.contains(opener) {
                destination.linkOpeners[page.id] = opener
            }
        }
        if let pendingAddressEntry, movedIDs.contains(pendingAddressEntry.paneID) { self.pendingAddressEntry = nil }
        zoomedPanes[tabID] = nil
        destination.zoomedPanes[nextDestination.selectedTab] = nil
        refreshTransferredTitles(&nextSource)
        session = nextSource
        // Publish source membership before retiring views: AppKit can request
        // layout synchronously while a WebView is being reparented.
        for id in movedIDs {
            mediaCoordinator.unregister(id)
            browsers.removeValue(forKey: id)?.webView.removeFromSuperview()
        }
        destination.session = nextDestination
        for id in replacedPages { destination.removeController(id) }
        // Extension adapters discover ownership from the final models, retaining
        // their existing identities throughout the move.
        if #available(macOS 15.4, *) {
            let manager = extensions
            let oldWindow = manager.window(for: self)
            for id in movedIDs {
                if let adapter = manager.tabs[id], let index = oldPageOrder.firstIndex(of: id) {
                    manager.controller.didMoveTab(adapter, from: index, in: oldWindow)
                }
            }
        }
        saveSoon(); destination.saveSoon()
        paneMoveRevision += 1; destination.paneMoveRevision += 1
        if emptiesWindow { onEmptiedByTransfer?(destination) }
        return true
    }

    func clearOpenTabsForPrivacy() {
        sleepingPanes.removeAll()
        // Explicit privacy clearing includes pinned panes and must not populate Reopen Closed Tab.
        for chat in chats.values { chat.stop() }
        chats.removeAll(); openChats.removeAll()
        let tab = BrowserTab()
        var cleared = session
        cleared.workspaces = [Workspace(name: "Tabs", tabs: [tab])]
        cleared.selectedTab = tab.id
        cleared.openChatTabs = []; cleared.activeChatIDs = [:]
        session = cleared
        closedItems.removeAll(); pendingAddressEntry = nil; linkOpeners.removeAll(); zoomedPanes.removeAll()
        save()
    }

    func stopWindow() {
        sleepObservation?.cancel(); sleepCoordinator?.stop(); sleepCoordinator = nil
        sleepingPanes.removeAll()
        for chat in chats.values { chat.stop() }
        mediaCoordinator.removeAll()
        save()
        windowStopped = true
        chats.removeAll(); openChats.removeAll()
        pendingSave?.cancel(); pendingSave = nil
        for page in browsers.values {
            page.permissionPrompt.cancel()
            page.certificates.cancel()
            page.fileUpload.cancel()
            page.stopCapture()
            page.webView.closeInspector()
            page.media.detach()
            page.webView.pauseAllMediaPlayback(completionHandler: nil)
            page.webView.stopLoading()
        }
        browsers.removeAll()
        if isPrivate {
            pendingHistorySave?.cancel(); pendingHistorySave = nil
            localHistory.clear(); closedItems.removeAll(); linkOpeners.removeAll()
            session = BrowserSession()
            downloads.shutdown(); downloads.clearFinished()
            websiteSettings.resetTemporary()
            privateWebsiteDataStore?.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
            privateWebsiteDataStore = nil
        }
        onAddressRequested = nil; onSettingsRequested = nil; onEmptiedByTransfer = nil; onNewWindowDrop = nil
        onNewLinkWindow = nil
    }

    func revealPage(_ id: UUID) {
        guard let tab = session.workspaces.flatMap(\.tabs).first(where: { $0.pages.contains { $0.id == id } }) else { return }
        select(tab.id); focus(id)
    }

    func closePage(_ id: UUID) {
        guard let wi = session.workspaces.firstIndex(where: { $0.tabs.contains { $0.pages.contains { $0.id == id } } }),
              let ti = session.workspaces[wi].tabs.firstIndex(where: { $0.pages.contains { $0.id == id } }) else { return }
        let tab = session.workspaces[wi].tabs[ti]
        guard tab.pages.first(where: { $0.id == id })?.isPinned == false else { return }
        if tab.pages.count == 1 { closeTab(tab.id); return }
        rememberClosed(.init(tab: snapshot(tab), workspaceID: session.workspaces[wi].id, tabIndex: ti, paneID: id, replacementID: nil))
        editTab(tab.id) { $0.closePane(id) }
        if zoomedPanes[tab.id] == id || tab.pages.count == 2 { zoomedPanes[tab.id] = nil }
        removeController(id)
    }

    private func tracePaneMembership() {
        var next: [UUID: UUID] = [:]
        for tab in session.workspaces.flatMap(\.tabs) {
            for page in tab.pages { next[page.id] = tab.id }
        }
        for (pane, tab) in next where diagnosticPaneTabs[pane] != tab {
            InputDiagnostics.transition(.paneMembership, diagnosticPaneTabs[pane] == nil ? .created : .changed,
                                        paneID: pane, tabID: tab)
        }
        for (pane, tab) in diagnosticPaneTabs where next[pane] == nil {
            InputDiagnostics.transition(.paneMembership, .removed, paneID: pane, tabID: tab)
        }
        diagnosticPaneTabs = next
    }

    func saveSoon() {
        tracePaneMembership()
        let pageIDs = Set(session.workspaces.flatMap(\.tabs).flatMap(\.pages).map(\.id))
        linkOpeners = linkOpeners.filter { pageIDs.contains($0.key) && pageIDs.contains($0.value) }
        if #available(macOS 15.4, *), let manager = extensionStorage as? ExtensionManager { manager.synchronizeTabs() }
        scheduleSessionSave()
    }

    private func scheduleSessionSave() {
        guard !isPrivate else { return }
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            self?.save()
        }
    }

    func save() {
        guard !isPrivate else { return }
        faviconCache?.flush()
        do {
            try FileManager.default.createDirectory(at: sessionFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            for chat in chats.values { chat.persist() }
            var saved = session
            if !windowStopped {
                saved.openChatTabs = Array(openChats)
                saved.activeChatIDs = chats.mapValues(\.conversationID)
                session = saved
            }
            saved.zoomedPanes = zoomedPanes.isEmpty ? nil : zoomedPanes
            try JSONEncoder().encode(saved).write(to: sessionFile, options: .atomic)
            persistenceError = nil
        } catch { persistenceError = "Session could not be saved: \(error.localizedDescription)" }
        saveHistory()
    }
}

// @lat: [[lat.md/architecture/web-pages#WebKit integration]]
@MainActor
class FocusWebView: WKWebView {
    var onOptionLink: ((String, Bool) -> Void)?
    private var inspectorSupport: BendInspectorSupport?
    var inspector: BendInspectorSupport {
        if let inspectorSupport { return inspectorSupport }
        let support = BendInspectorSupport(webView: self)
        support.onFrontendReady = { [weak self] frontend in
            (self?.superview as? WebSurfaceHost)?.installInspectorFrontend(frontend)
        }
        support.onAction = { [weak self] action in
            guard let self else { return }
            if action == "close" { closeInspector() }
            else if action == "bottom" || action == "right" {
                (superview as? WebSurfaceHost)?.dockDeveloperTools(action == "right" ? .right : .bottom)
            }
        }
        inspectorSupport = support
        return support
    }
    var hasOpenInspector: Bool { inspectorSupport?.isVisible == true }
    func closeInspector() {
        (superview as? WebSurfaceHost)?.removeDeveloperTools()
        inspectorSupport?.invalidate()
        inspectorSupport = nil
    }
    weak var mediaController: PageMediaController?
    var hoveredLink = "" {
        didSet { (superview as? WebSurfaceHost)?.showLinkPreview(hoveredLink) }
    }

    func clearURLPreview() {
        (superview as? WebSurfaceHost)?.showTitlePreview("")
        hoveredLink = ""
    }

    override init(frame: NSRect, configuration: WKWebViewConfiguration) {
        // WebKit defaults this off, including for video players' fullscreen controls.
        configuration.preferences.isElementFullscreenEnabled = true
        LinkHoverObserver.install(in: configuration.userContentController)
        MediaSessionBridge.install(in: configuration.userContentController)
        super.init(frame: frame, configuration: configuration)
        BendInspectorSupport.enable(for: self)
    }

    required init?(coder: NSCoder) { return nil }

    var onDialogInvalidated: (() -> Void)?
    override func viewDidHide() {
        super.viewDidHide()
        onDialogInvalidated?()
    }

    var diagnosticPaneID: UUID?
    var onFocus: (() -> Void)?
    override func cancelOperation(_ sender: Any?) {
        if let surface = superview as? WebSurfaceHost, surface.isFindBarVisible {
            surface.performFindAction(.hideFindInterface)
        }
        // WebKit calls this after offering Escape to the page. With no find
        // bar, there is nothing to cancel; the superclass has no implementation
        // of this optional responder action to call.
    }
    override func mouseDown(with event: NSEvent) {
        InputDiagnostics.record(.webView, event: event, view: self)
        defer { InputDiagnostics.record(.webViewReturned, event: event, view: self) }
        onFocus?()
        super.mouseDown(with: event)
    }
    override func mouseDragged(with event: NSEvent) {
        InputDiagnostics.record(.webView, event: event, view: self)
        defer { InputDiagnostics.record(.webViewReturned, event: event, view: self) }
        super.mouseDragged(with: event)
    }
    override func mouseUp(with event: NSEvent) {
        InputDiagnostics.record(.webView, event: event, view: self)
        defer { InputDiagnostics.record(.webViewReturned, event: event, view: self) }
        super.mouseUp(with: event)
    }
    override func becomeFirstResponder() -> Bool {
        InputDiagnostics.transition(.webFocus, .requested, view: self)
        onFocus?()
        let accepted = super.becomeFirstResponder()
        InputDiagnostics.transition(.webFocus, accepted ? .allowed : .denied, view: self)
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        BendSelectionSupport.enable(for: self)
        let accepted = super.resignFirstResponder()
        InputDiagnostics.transition(.webFocus, .finished, view: self, flags: ["accepted": accepted])
        return accepted
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        let accepted = super.acceptsFirstMouse(for: event)
        InputDiagnostics.transition(.webFocus, accepted ? .allowed : .denied, event: event, view: self, flags: ["firstMouse": true])
        return accepted
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { onDialogInvalidated?() }
        clearURLPreview()
        InputDiagnostics.transition(.webAttachment, window == nil ? .detached : .attached, view: self)
    }
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview == nil { onDialogInvalidated?() }
        clearURLPreview()
        InputDiagnostics.transition(.webAttachment, superview == nil ? .detached : .attached, view: self, flags: ["superview": true])
    }
}

@MainActor
final class PageController: BendContextMenuDelegate, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    static let privateExtensionPageError = "Extension pages are unavailable in private windows because their website storage cannot be isolated."
    let isPrivate: Bool
    let downloads: BrowserDownloads
    let media = PageMediaController()
    @Published private(set) var webView: FocusWebView
    private(set) var aiNavigationRevision = UUID()
    var configure: (WKWebViewConfiguration) -> Void
    private var extensionOrigin: URL?
    @Published var address: String
    @Published var title = "New tab"
    @Published var favicon: NSImage? { didSet { onFaviconChanged?() } }
    var onFaviconChanged: (() -> Void)?
    private var faviconTask: Task<Void, Never>?
    private var faviconPageURL: URL?
    private let faviconCache: FaviconCache?
    @Published var isLoading = false
    @Published var progress = 0.0
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var error: String? { didSet { if error != nil { wakeSnapshot = nil } } }
    @Published private(set) var certificateFailure: (url: URL, exception: CertificateException)?
    private var certificateExceptions: Set<CertificateException> = []

    var usesCertificateException: Bool {
        guard !isStartPage,
              WebsiteCertificates.matchesSite(webView.url, committed: committedSiteURL),
              let url = committedSiteURL, let trust = webView.serverTrust,
              let exception = CertificateException(url: url, trust: trust) else { return false }
        return certificateExceptions.contains(exception)
    }

    func continueDespiteCertificateError() {
        guard error != nil, let failure = certificateFailure else { return }
        certificateExceptions.insert(failure.exception)
        navigate(failure.url.absoluteString)
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        var components = URLComponents()
        components.scheme = space.protocol
        components.host = space.host
        components.port = space.port
        if webView === self.webView, space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = space.serverTrust, let url = components.url {
            certificates.record(trust, for: url)
            objectWillChange.send()
        }
        if webView === self.webView, space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = space.serverTrust, let url = components.url,
           let exception = CertificateException(url: url, trust: trust),
           certificateExceptions.contains(exception) {
            // Apply the accepted validation failures to this trust object only.
            // WebKit still evaluates the supplied credential's trust.
            if let exceptions = SecTrustCopyExceptions(trust), SecTrustSetExceptions(trust, exceptions) {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
    @Published var isStartPage = true
    var onNavigation: ((String, String) -> Void)?
    var onStateChanged: (() -> Void)?
    var canCloseFromHistory: (() -> Bool)?
    var onCloseFromHistory: (() -> Void)?
    private var historySwipeGuard: HistorySwipeGuard?
    private let seedCloseHistory: Bool
    private(set) var closeHistoryURL: URL?
    private var pendingCloseHistoryDestination: URL?
    var backItemClosesPage: Bool { closeHistoryURL != nil && webView.backForwardList.backItem?.url == closeHistoryURL }
    var onNewTab: ((String) -> Void)?
    var onNewPane: ((String) -> Void)?
    var onNewLink: ((String, Bool, Bool) -> Void)?
    var onCommandShiftLink: ((String, Bool) -> Void)?
    var onOptionLink: ((String, Bool) -> Void)?
    var onOpenLink: ((String, Bool, LinkOpenDestination) -> Void)?
    var onInitialDownload: (() -> Void)?
    var onFocus: (() -> Void)?
    private var observations: [NSKeyValueObservation] = []
    var onVisit: ((String, String) -> Void)?
    var onHistoryTitleChanged: ((String, String) -> Void)?
    private var completedAddress: String?
    private var lastReportedAddress = ""
    private var lastReportedTitle = ""
    var customSearchEngine: () -> CustomSearchEngine?
    var searchEngine: () -> SearchEngine
    let fileUpload = WebsiteFileUpload()
    let certificates = WebsiteCertificates()
    var certificateTrust: SecTrust? {
        guard !isStartPage, !isLoading, error == nil else { return nil }
        return certificates.trust(for: webView, committedURL: committedSiteURL)
    }

    func showCertificates() {
        guard let trust = certificateTrust else { return }
        certificates.show(trust, for: webView)
    }

    @Published var committedSiteURL: URL?
    let permissionPrompt = WebsitePermissionPrompt()
    @Published var cameraCaptureState: WKMediaCaptureState = .none
    @Published var microphoneCaptureState: WKMediaCaptureState = .none
    var captureRequestOrigins: [WebsitePermission: Set<String>] = [:]
    var lastPermissionBlocks: [String: Set<WebsitePermission>] = [:]
    let websiteSettings: WebsiteSettingsStore?
    private var websiteSettingsObservation: AnyCancellable?
    private var zoomURL: URL?
    private var localDocumentDirectory: URL?
    private let externalApplications: ExternalApplicationLinks
    private let javaScriptDialogs: JavaScriptDialogs
    private(set) var sleepNavigationRevision = 0
    private var trackSleep: Bool
    private var sleepMayResubmit = false
    @Published var wakeSnapshot: NSImage?
    var canSleep: Bool {
        certificateExceptions.isEmpty && !sleepMayResubmit && !isStartPage && error == nil && !isLoading && !webView.isLoading &&
        webView.cameraCaptureState == .none && webView.microphoneCaptureState == .none &&
        !webView.hasOpenInspector && webView.window?.attachedSheet == nil &&
        !javaScriptDialogs.hasPending(for: webView) && !downloads.hasActiveDownload(for: webView) &&
        !media.sessions.contains(where: \.playing)
    }

    // WebKit's default user agent omits Safari's product tokens. Some sites
    // consequently serve a legacy, fixed-width page to an otherwise modern engine.
    static let websiteApplicationName: String = {
        let safariVersion = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari")
            .flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }
        let version = safariVersion.map { $0.split(separator: ".").prefix(2).joined(separator: ".") } ?? "17.0"
        return "Version/\(version) Safari/605.1.15 Bend/0.1"
    }()

    init(address: String, paneID: UUID? = nil, isPrivate: Bool = false, webView suppliedWebView: FocusWebView? = nil, websiteSettings: WebsiteSettingsStore? = nil, faviconCache: FaviconCache? = nil,
         seedCloseHistory: Bool = false, externalApplications: ExternalApplicationLinks = .shared, javaScriptDialogs: JavaScriptDialogs = .shared,
         downloads: BrowserDownloads = BrowserDownloads(), searchEngine: SearchEngine = .google, customSearchEngine: CustomSearchEngine? = nil, sleeping: SleepingPane? = nil, trackSleep: Bool = false, configure: @escaping (WKWebViewConfiguration) -> Void = { _ in }) {
        self.trackSleep = trackSleep
        self.seedCloseHistory = seedCloseHistory
        self.address = address
        self.isStartPage = URL(string: AddressResolver.canonicalAddress(address))?.scheme == "bend"
        self.isPrivate = isPrivate
        self.downloads = downloads
        self.externalApplications = externalApplications
        self.javaScriptDialogs = javaScriptDialogs
        self.websiteSettings = websiteSettings
        self.searchEngine = { searchEngine }
        self.customSearchEngine = { customSearchEngine }
        self.faviconCache = isPrivate ? nil : faviconCache
        self.configure = configure
        let configuration = WKWebViewConfiguration()
        configuration.applicationNameForUserAgent = Self.websiteApplicationName
        configuration.websiteDataStore = AppProfile.current.websiteDataStore
        configure(configuration)
        if URL(string: AddressResolver.canonicalAddress(address))?.scheme == "bend" { configuration.webExtensionController = nil }
        WebKitPrivacy.apply(websiteSettings?.values ?? WebsiteSettings(), to: configuration)
        if seedCloseHistory { configuration.setURLSchemeHandler(CloseHistoryPage(), forURLScheme: "bend") }
        webView = suppliedWebView ?? FocusWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.diagnosticPaneID = paneID
        InputDiagnostics.transition(.webReplacement, .created, view: webView)
        observeWebView()
        if let sleeping {
            closeHistoryURL = sleeping.closeHistoryURL
            self.address = sleeping.address; title = sleeping.title; isStartPage = false
            wakeSnapshot = NSImage(data: sleeping.snapshot)
            webView.interactionState = sleeping.interactionState
            webView.pageZoom = sleeping.zoom
            let navigation = webView.backForwardList.currentItem.flatMap { webView.go(to: $0) }
            if navigation == nil { navigate(sleeping.address) }
        } else { navigate(address) }
        websiteSettingsObservation = websiteSettings?.$values.sink { [weak self] values in
            guard let self else { return }
            self.applyWebsiteSecurity(values)
            self.applyCaptureRestrictions(values)
            guard let url = self.zoomURL, WebsiteSettings.hostname(for: url) != nil else { return }
            self.webView.pageZoom = CGFloat(values.zoom(for: url))
        }
    }

    func prepareForSleep() {
        faviconTask?.cancel(); faviconTask = nil
        observations.removeAll()
        onNavigation = nil; onStateChanged = nil; onFocus = nil
        onFaviconChanged = nil; onVisit = nil; onHistoryTitleChanged = nil
        media.detach()
        webView.onFocus = nil; webView.onDialogInvalidated = nil
        webView.navigationDelegate = nil; webView.uiDelegate = nil
        webView.removeFromSuperview()
    }

    private func applyWebsiteSecurity(_ values: WebsiteSettings) {
        guard extensionOrigin == nil else { return }
        WebKitPrivacy.apply(values, to: webView.configuration)
        webView.configuration.preferences.isFraudulentWebsiteWarningEnabled = values.warnFraudulentSites
        webView.configuration.websiteDataStore.httpCookieStore.setCookiePolicy(values.blockAllCookies ? .disallow : .allow)
    }

    func setPageZoom(_ zoom: CGFloat) {
        guard PageZoom.isValid(Double(zoom)) else { return }
        webView.pageZoom = zoom
        if let zoomURL { websiteSettings?.setZoom(Double(zoom), for: zoomURL) }
    }

    private func applyWebsiteZoom(for url: URL) {
        zoomURL = url
        if let websiteSettings { webView.pageZoom = CGFloat(websiteSettings.values.zoom(for: url)) }
    }

    func setSleepTracking(_ enabled: Bool) {
        trackSleep = enabled
        let scripts = webView.configuration.userContentController
        if enabled { PaneSleepProbe.install(in: scripts) }
        else { PaneSleepProbe.remove(from: scripts) }
    }

    private func observeWebView() {
        historySwipeGuard = HistorySwipeGuard(webView: webView) { [weak self] in
            guard let self else { return false }
            return self.backItemClosesPage && self.canCloseFromHistory?() != true
        }
        applyWebsiteSecurity(websiteSettings?.values ?? WebsiteSettings())
        if trackSleep { PaneSleepProbe.install(in: webView.configuration.userContentController) }
        OptionClickObserver.install(in: webView.configuration.userContentController)
        webView.onOptionLink = { [weak self] address, mainFrame in
            self?.onOptionLink?(address, mainFrame)
        }
        media.attach(to: webView)
        InputDiagnostics.transition(.extensionConfiguration, .changed, view: webView)
        webView.navigationDelegate = self; webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = true
        webView.onFocus = { [weak self] in self?.onFocus?() }
        webView.onDialogInvalidated = { [weak self] in
            guard let self else { return }
            self.javaScriptDialogs.cancel(for: self.webView)
            self.permissionPrompt.cancel()
            self.certificates.cancel()
            self.fileUpload.cancel()
        }
        refreshCaptureState()
        observations = [
            webView.observe(\.serverTrust) { [weak self] _, _ in Task { @MainActor in self?.objectWillChange.send() } },
            webView.observe(\.hasOnlySecureContent) { [weak self] _, _ in Task { @MainActor in self?.objectWillChange.send() } },
            webView.observe(\.cameraCaptureState) { [weak self] _, _ in Task { @MainActor in self?.refreshCaptureState() } },
            webView.observe(\.microphoneCaptureState) { [weak self] _, _ in Task { @MainActor in self?.refreshCaptureState() } },
            webView.observe(\.estimatedProgress) { [weak self] _, _ in Task { @MainActor in self?.refresh() } },
            webView.observe(\.isLoading) { [weak self] _, _ in Task { @MainActor in self?.refresh() } },
            webView.observe(\.title) { [weak self] _, _ in Task { @MainActor in self?.refresh() } },
            webView.observe(\.canGoBack) { [weak self] _, _ in Task { @MainActor in self?.refresh() } },
            webView.observe(\.canGoForward) { [weak self] _, _ in Task { @MainActor in self?.refresh() } },
            webView.observe(\.url) { [weak self] _, _ in Task { @MainActor in self?.refresh() } }
        ]
    }

    private func replaceWebView(configuration: WKWebViewConfiguration) {
        closeHistoryURL = nil; pendingCloseHistoryDestination = nil
        if seedCloseHistory, configuration.urlSchemeHandler(forURLScheme: "bend") == nil {
            configuration.setURLSchemeHandler(CloseHistoryPage(), forURLScheme: "bend")
        }
        certificates.reset()
        InputDiagnostics.transition(.webReplacement, .started, view: webView)
        stopCapture()
        captureRequestOrigins.removeAll()
        javaScriptDialogs.cancel(for: webView)
        permissionPrompt.cancel()
        certificates.cancel()
        fileUpload.cancel()
        webView.closeInspector()
        webView.onDialogInvalidated = nil
        observations.removeAll()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.onFocus = nil
        webView.onOptionLink = nil
        webView.stopLoading()
        let paneID = webView.diagnosticPaneID
        webView = FocusWebView(frame: webView.frame, configuration: configuration)
        webView.diagnosticPaneID = paneID
        canGoBack = false; canGoForward = false
        observeWebView()
        InputDiagnostics.transition(.webReplacement, .finished, view: webView)
    }

    // Only the extension host may authorize a top-level extension document.
    func navigateExtension(_ url: URL, configuration: WKWebViewConfiguration) {
        guard !isPrivate else { error = Self.privateExtensionPageError; return }
        onInitialDownload = nil
        if extensionOrigin?.scheme != url.scheme || extensionOrigin?.host != url.host {
            extensionOrigin = url
            replaceWebView(configuration: configuration)
        }
        load(url)
    }

    func unloadExtension(at origin: URL) {
        guard extensionOrigin?.scheme == origin.scheme, extensionOrigin?.host == origin.host else { return }
        navigate("bend://start")
        error = "This extension page is unavailable. Enable its extension in Settings."
    }

    func navigate(_ input: String) {
        onInitialDownload = nil
        let localURL = URL(string: input).flatMap { LocalWebDocument.accepts($0) ? $0 : nil }
        guard let url = localURL ?? AddressResolver.resolve(input, searchEngine: searchEngine(), customSearchEngine: customSearchEngine()) else { error = "Enter a web address or search phrase."; return }
        let nativePage = url.scheme == "bend"
        if extensionOrigin != nil || nativePage != isStartPage || (nativePage && webView.configuration.webExtensionController != nil) {
            extensionOrigin = nil
            let configuration = WKWebViewConfiguration()
            configuration.applicationNameForUserAgent = Self.websiteApplicationName
            configuration.websiteDataStore = AppProfile.current.websiteDataStore
            configure(configuration)
            if nativePage { configuration.webExtensionController = nil }
            WebKitPrivacy.apply(websiteSettings?.values ?? WebsiteSettings(), to: configuration)
            replaceWebView(configuration: configuration)
        }
        load(url)
    }

    private func load(_ url: URL) {
        aiNavigationRevision = UUID()
        javaScriptDialogs.cancel(for: webView)
        permissionPrompt.cancel()
        certificates.cancel()
        fileUpload.cancel()
        webView.clearURLPreview()
        InputDiagnostics.transition(.webLoad, .requested, view: webView, flags: ["internal": url.scheme == "bend"])
        resetFavicon(for: url)
        certificateFailure = nil
        error = nil; address = url.absoluteString
        completedAddress = nil
        isStartPage = url.scheme == "bend"
        localDocumentDirectory = url.isFileURL ? url.deletingLastPathComponent() : nil
        // A reused view still displays the outgoing document until commit.
        // Only a fresh view (or native internal page) can take the target zoom now.
        if isStartPage || webView.url == nil { applyWebsiteZoom(for: url) }
        if isStartPage {
            stopCapture()
            webView.closeInspector()
            webView.stopLoading()
            if webView.url != nil {
                media.detach()
                webView.pauseAllMediaPlayback(completionHandler: nil)
            }
            title = address == "bend://start" ? "New tab" : AddressResolver.nativePageTitle(address) ?? "New tab"
            reportNavigation()
        } else {
            if seedCloseHistory, closeHistoryURL == nil, webView.backForwardList.currentItem == nil,
               let marker = URL(string: "bend://close/" + UUID().uuidString) {
                closeHistoryURL = marker
                pendingCloseHistoryDestination = url
                webView.load(URLRequest(url: marker))
                return
            }
            if pendingCloseHistoryDestination != nil {
                pendingCloseHistoryDestination = url
                return
            }
            if webView.mediaController == nil { media.attach(to: webView) }
            if let localDocumentDirectory { webView.loadFileURL(url, allowingReadAccessTo: localDocumentDirectory) }
            else { webView.load(URLRequest(url: url)) }
        }
    }

    func refresh() {
        historySwipeGuard?.historyDidChange()
        defer { onStateChanged?() }
        isLoading = webView.isLoading; progress = webView.estimatedProgress
        canGoBack = webView.canGoBack && (!backItemClosesPage || canCloseFromHistory?() == true)
        canGoForward = webView.canGoForward
        guard pendingCloseHistoryDestination == nil, webView.url != closeHistoryURL || closeHistoryURL == nil else { return }
        if !isStartPage {
            if let url = webView.url {
                discardFavicon(ifLeaving: url)
                address = url.absoluteString
            }
            title = webView.title.flatMap { $0.isEmpty ? nil : $0 } ?? webView.url?.host ?? "New tab"
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

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
        aiNavigationRevision = UUID()
        javaScriptDialogs.cancel(for: webView)
        permissionPrompt.cancel()
        certificates.cancel()
        fileUpload.cancel()
        (webView as? FocusWebView)?.clearURLPreview()
        (webView.superview as? WebSurfaceHost)?.hideFindBar(restoreFocus: false)
        sleepNavigationRevision += 1
        InputDiagnostics.transition(.webLoad, .started, view: webView)
        resetFavicon(for: webView.url ?? URL(string: address))
        completedAddress = nil
        certificateFailure = nil
        if !isStartPage { error = nil }
    }
    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation?) {
        resetFavicon(for: webView.url)
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation?) {
        if let marker = closeHistoryURL, webView.url == marker { return }
        aiNavigationRevision = UUID()
        onInitialDownload = nil
        discardFavicon(ifLeaving: webView.url)
        committedSiteURL = webView.url
        javaScriptDialogs.didCommitNavigation(in: webView)
        captureRequestOrigins.removeAll()
        if webView.url?.isFileURL != true { localDocumentDirectory = nil }
        // The committed URL covers redirects, normal links, and back/forward.
        // Subframe navigation never changes the top-level website's preference.
        if !isStartPage, let url = webView.url { applyWebsiteZoom(for: url) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        wakeSnapshot = nil
        if let marker = closeHistoryURL, webView.url == marker,
           let destination = pendingCloseHistoryDestination {
            pendingCloseHistoryDestination = nil
            load(destination)
            return
        }
        InputDiagnostics.transition(.webLoad, .finished, view: webView)
        refresh()
        recordCompletedVisit()
        refreshFavicon()
    }

    private func refreshFavicon() {
        guard !isStartPage, let url = webView.url else { return }
        let webView = webView
        faviconTask?.cancel()
        faviconTask = Task { [weak self] in
            let candidates = await FaviconLoader.candidates(in: webView, pageURL: url)
            guard !Task.isCancelled else { return }
            let image = await FaviconLoader.load(candidates, in: webView)
            guard !Task.isCancelled, let self, self.webView === webView, !self.isStartPage else { return }
            guard webView.url == url else {
                // History API navigation doesn't call didFinish. An icon load
                // abandoned because its URL changed needs a fresh attempt.
                if FaviconLoader.sameOrigin(url, webView.url) { self.refreshFavicon() }
                return
            }
            guard let image else { return }
            self.faviconCache?.record(image, for: url)
            self.faviconPageURL = url
            self.favicon = image
        }
    }

    private func resetFavicon(for destination: URL?) {
        faviconTask?.cancel()
        faviconTask = nil
        discardFavicon(ifLeaving: destination)
    }

    private func discardFavicon(ifLeaving destination: URL?) {
        // Keep the last successful icon through same-origin navigation and failed
        // refreshes, but never let another origin inherit its visual identity.
        guard !FaviconLoader.sameOrigin(faviconPageURL, destination) else { return }
        faviconPageURL = nil
        if let destination, let cached = faviconCache?.image(for: destination) {
            faviconPageURL = destination
            favicon = cached
        } else if favicon != nil { favicon = nil }
    }

    deinit { faviconTask?.cancel() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) { show(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) { show(error) }
    func show(_ failure: Error) {
        wakeSnapshot = nil
        InputDiagnostics.transition(.webLoad, .cancelled, view: webView)
        completedAddress = nil
        let nativeError = failure as NSError
        // WebKit still uses the legacy policy-interruption error when a
        // navigation becomes a WKDownload. The existing page remains valid.
        let policyInterruption = nativeError.domain == "WebKitErrorDomain" && nativeError.code == 102
        let cancelled = nativeError.domain == NSURLErrorDomain && nativeError.code == NSURLErrorCancelled
        if !cancelled && !policyInterruption {
            certificateFailure = CertificateException.failure(nativeError)
            error = failure.localizedDescription
        }
        refresh()
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        media.reset()
        javaScriptDialogs.cancel(for: webView)
        permissionPrompt.cancel()
        certificates.cancel()
        fileUpload.cancel()
        InputDiagnostics.transition(.webProcessExit, .finished, view: webView)
        error = "This page stopped responding. Reload to continue."
    }
    private func openOptionClickedLink(_ action: WKNavigationAction) -> Bool {
        guard action.navigationType == .linkActivated, action.buttonNumber == 1,
              action.modifierFlags.contains(.option),
              action.modifierFlags.intersection([.command, .control]).isEmpty,
              let url = action.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let onOptionLink else { return false }
        onOptionLink(url.absoluteString, action.sourceFrame.isMainFrame)
        return true
    }

    private func openCommandClickedLink(_ action: WKNavigationAction) -> Bool {
        // WebKit reports left-click as 1 (a button mask), unlike NSEvent's zero-based buttonNumber.
        guard action.navigationType == .linkActivated, action.modifierFlags.contains(.command),
              action.buttonNumber == 1, let url = action.request.url,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        if action.modifierFlags.contains(.shift) {
            guard onCommandShiftLink != nil || onNewTab != nil else { return false }
            InputDiagnostics.transition(.commandLink, .allowed, view: webView)
            if let onCommandShiftLink { onCommandShiftLink(url.absoluteString, action.sourceFrame.isMainFrame) }
            else { onNewTab?(url.absoluteString) }
            return true
        }
        guard let onNewPane else { return false }
        InputDiagnostics.transition(.commandLink, .allowed, view: webView)
        if let onNewLink { onNewLink(url.absoluteString, true, action.sourceFrame.isMainFrame) }
        else { onNewPane(url.absoluteString) }
        return true
    }

    private func openExternalApplication(_ action: WKNavigationAction, from webView: WKWebView) -> Bool {
        guard let url = action.request.url, ExternalApplicationLinks.isExternal(url) else { return false }
        if let window = webView.window, !webView.isHiddenOrHasHiddenAncestor {
            externalApplications.request(url, source: action.sourceFrame.request.url ?? webView.url, in: window)
        }
        return true
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        let values = websiteSettings?.values ?? WebsiteSettings()
        // Extension documents keep their own scripting requirements. Website
        // policy is resolved for every navigation, including reused views.
        if extensionOrigin == nil {
            WebKitPrivacy.enableAdvancedProtection(preferences)
            preferences.allowsContentJavaScript = values.javaScriptEnabled
            preferences.preferredHTTPSNavigationPolicy = values.warnHTTP ? .userMediatedFallbackToHTTP : .keepAsRequested
        }
        self.webView(webView, decidePolicyFor: action) { policy in decisionHandler(policy, preferences) }
    }

    // Reject our sentinel at WebKit's history-traversal boundary, before it
    // restores a cached page or starts ordinary navigation policy/loading.
    func webView(_ webView: WKWebView, shouldGoTo backForwardListItem: WKBackForwardListItem,
                 willUseInstantBack: Bool, completionHandler: @escaping @MainActor (Bool) -> Void) {
        guard let marker = closeHistoryURL, backForwardListItem.url == marker else {
            completionHandler(true)
            return
        }
        completionHandler(false)
        closeFromHistoryIfAllowed()
    }

    private func closeFromHistoryIfAllowed() {
        guard canCloseFromHistory?() == true else { return }
        Task { @MainActor [weak self] in
            guard let self, self.canCloseFromHistory?() == true else { return }
            self.onCloseFromHistory?()
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // History restoration may replay a form submission. Keep this controller
        // awake after non-GET navigation, even across subsequent redirects.
        if action.targetFrame?.isMainFrame == true, action.request.httpMethod != "GET" {
            sleepMayResubmit = true
        }
        InputDiagnostics.transition(.navigationPolicy, .requested, view: webView, flags: [
            "link": action.navigationType == .linkActivated, "command": action.modifierFlags.contains(.command),
            "mainFrame": action.targetFrame?.isMainFrame == true, "newWindow": action.targetFrame == nil
        ])
        let originalHandler = decisionHandler
        let decisionHandler: (WKNavigationActionPolicy) -> Void = { policy in
            InputDiagnostics.transition(.navigationPolicy, policy == .allow ? .allowed : .denied, view: webView)
            if policy == .allow, action.targetFrame?.isMainFrame == true {
                self.resetFavicon(for: action.request.url)
            }
            originalHandler(policy)
        }
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if let marker = closeHistoryURL, url == marker {
            if pendingCloseHistoryDestination != nil, action.navigationType != .backForward {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
                if action.navigationType == .backForward, action.targetFrame?.isMainFrame == true,
                   canCloseFromHistory?() == true {
                    closeFromHistoryIfAllowed()
                }
            }
            return
        }
        if openOptionClickedLink(action) { decisionHandler(.cancel); return }
        if action.shouldPerformDownload, BrowserDownloads.supports(url) {
            decisionHandler(.download)
            return
        }
        if url.isFileURL {
            let allowed = localDocumentDirectory.map { LocalWebDocument.contains(url, in: $0) } ?? false
            decisionHandler(allowed ? .allow : .cancel)
            return
        }
        if openCommandClickedLink(action) { decisionHandler(.cancel); return }
        if #available(macOS 15.4, *),
           let context = webView.configuration.webExtensionController?.extensionContext(for: url), context.isLoaded,
           webView.configuration.websiteDataStore.isPersistent || context.hasAccessToPrivateData {
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
        if openExternalApplication(action, from: webView) { decisionHandler(.cancel); return }
        decisionHandler(["https", "http", "about"].contains(url.scheme?.lowercased() ?? "") ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?
            .split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces).lowercased()
        let shouldDownload = !response.canShowMIMEType || disposition == "attachment"
        decisionHandler(shouldDownload && BrowserDownloads.supports(response.response.url) ? .download : .allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        downloads.receive(download, from: webView)
        if navigationAction.targetFrame?.isMainFrame == true { finishInitialDownload() }
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        downloads.receive(download, from: webView)
        if navigationResponse.isForMainFrame { finishInitialDownload() }
    }

    private func finishInitialDownload() {
        let completion = onInitialDownload
        onInitialDownload = nil
        completion?()
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        InputDiagnostics.transition(.newWindowLink, .requested, view: webView)
        if openOptionClickedLink(action) { return nil }
        if action.shouldPerformDownload, BrowserDownloads.supports(action.request.url) {
            downloads.start(action.request, in: webView)
            return nil
        }
        if openCommandClickedLink(action) { return nil }
        if openExternalApplication(action, from: webView) { return nil }
        if action.targetFrame == nil, let url = action.request.url,
           ["http", "https"].contains(url.scheme ?? "") {
            InputDiagnostics.transition(.newWindowLink, .allowed, view: webView)
            if let onNewLink { onNewLink(url.absoluteString, false, action.sourceFrame.isMainFrame) }
            else { onNewTab?(url.absoluteString) }
        } else { InputDiagnostics.transition(.newWindowLink, .denied, view: webView) }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        javaScriptDialogs.request(.init(kind: .alert, origin: JavaScriptDialogs.originLabel(frame.securityOrigin), message: message),
                                  from: webView) { _ in completionHandler() }
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        javaScriptDialogs.request(.init(kind: .confirm, origin: JavaScriptDialogs.originLabel(frame.securityOrigin), message: message),
                                  from: webView) { completionHandler($0.accepted) }
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
        javaScriptDialogs.request(.init(kind: .prompt, origin: JavaScriptDialogs.originLabel(frame.securityOrigin),
                                       message: prompt, defaultText: defaultText ?? ""),
                                  from: webView) { completionHandler($0.text) }
    }
}
