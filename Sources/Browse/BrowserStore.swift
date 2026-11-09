import AppKit
import Combine
import WebKit
import BrowseCore
import WebKitFindSupport

@MainActor
final class BrowserStore: ObservableObject {
    @Published var session: BrowserSession
    @Published var favoriteCustomization: FavoriteCustomizationRequest?
    @Published var sidebarVisible = true {
        didSet { if sidebarVisible { sidebarFloating = false } }
    }
    @Published var sidebarFloating = false
    @Published var isFullScreen = false
    @Published var zoomedPane: UUID?
    let mediaCoordinator = WindowMediaCoordinator()
    let mediaPlaybackFocus: MediaPlaybackFocus
    let downloads: BrowserDownloads
    @Published private(set) var paneMoveRevision = 0
    var onAddressRequested: ((UUID) -> Void)?
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
    let sharedStore: BrowserStore?
    let websiteSettings: WebsiteSettingsStore
    private var sharedObservation: AnyCancellable?
    var preferencesStore: BrowserStore { sharedStore?.preferencesStore ?? self }
    var historyPublisher: AnyPublisher<BrowsingHistory, Never> {
        sharedStore?.historyPublisher ?? $localHistory.eraseToAnyPublisher()
    }
    private(set) var history: BrowsingHistory {
        get { sharedStore?.history ?? localHistory }
        set { localHistory = newValue }
    }
    private(set) var historyError: String? {
        get { sharedStore?.historyError ?? localHistoryError }
        set { localHistoryError = newValue }
    }
    private var browsers: [UUID: PageController] = [:]
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
    private var pendingHistorySave: Task<Void, Never>?
    private var historyDirty = false
    private var historyWritable = true

    init(sessionFile: URL? = nil, persistentExtensions: Bool = true, extensionManager: AnyObject? = nil, sharedStore: BrowserStore? = nil) {
        self.sharedStore = sharedStore
        mediaPlaybackFocus = sharedStore?.mediaPlaybackFocus ?? MediaPlaybackFocus()
        self.persistentExtensions = sharedStore?.persistentExtensions ?? persistentExtensions
        let root = AppProfile.current.supportDirectory
        self.sessionFile = sessionFile ?? root.appendingPathComponent("session.json")
        downloads = sharedStore?.downloads ?? BrowserDownloads(
            databaseFile: self.sessionFile.deletingLastPathComponent().appendingPathComponent("Downloads.db"))
        websiteSettings = sharedStore?.websiteSettings ?? WebsiteSettingsStore(
            file: self.sessionFile.deletingLastPathComponent().appendingPathComponent("WebsiteSettings.db"))
        historyFile = self.sessionFile.deletingLastPathComponent().appendingPathComponent("History.db")
        legacyHistoryFile = self.sessionFile.deletingLastPathComponent().appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: self.sessionFile),
           let restored = try? JSONDecoder().decode(BrowserSession.self, from: data), restored.isValid {
            session = restored
        } else { session = BrowserSession() }
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
        if sharedStore == nil {
            do {
                let database = try HistoryDatabase(file: historyFile, legacyFile: legacyHistoryFile)
                historyDatabase = database
                history = database.load()
            } catch {
                historyWritable = false
                historyError = "Saved history could not be read. Clear history to reset it."
            }
        }
        if sharedStore == nil { downloads.directory = downloadDirectory }
        tracePaneMembership()
        extensionStorage = extensionManager
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

    // @lat: [[architecture#UI preferences]]
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

    var commandShiftClickDestination: CommandShiftClickDestination {
        get { sharedStore?.commandShiftClickDestination ?? session.commandShiftClickDestination ?? .newTab }
        set {
            if let sharedStore { sharedStore.commandShiftClickDestination = newValue; return }
            session.commandShiftClickDestination = newValue
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

    static let defaultSidebarWidth: CGFloat = 250
    static let sidebarWidthRange: ClosedRange<CGFloat> = 200...400

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
        session.selectedTab = id; zoomedPane = nil; saveSoon()
    }
    func focus(_ id: UUID) {
        InputDiagnostics.transition(.storeFocus, selectedTab.focusedPane == id ? .unchanged : .requested, paneID: id)
        guard selectedTab.focusedPane != id, selectedTab.pages.contains(where: { $0.id == id }) else { return }
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
        editTab(tab.id) {
            $0.split(axis: .horizontal, after: source, address: address)
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
    func resize(_ id: UUID, fraction: Double) { editTab { $0.layout = $0.layout.resizing(id, to: fraction) } }
    @discardableResult
    func movePane(_ source: UUID, beside target: UUID, edge: PaneDropEdge, in tabID: UUID, from sourceTabID: UUID? = nil) -> Bool {
        InputDiagnostics.transition(.paneMove, .requested, paneID: source, tabID: tabID, relatedPaneID: target)
        guard selectedTab.id == tabID, zoomedPane == nil else { return false }
        if let sourceTabID, sourceTabID != tabID {
            var next = session
            guard next.transferPane(source, from: sourceTabID, beside: target, in: tabID, edge: edge) else { return false }
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
        zoomedPane = nil
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
        zoomedPane = nil
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

    func newTab(in workspace: UUID? = nil, address: String = "browse://start", linkOpener: UUID? = nil,
                closeIfDownload: Bool = false, afterCurrent: Bool = false) {
        let previousTabID = session.selectedTab, previousZoom = zoomedPane
        let index = session.workspaces.firstIndex { $0.id == workspace }
            ?? session.workspaces.firstIndex { $0.tabs.contains { $0.id == session.selectedTab } } ?? 0
        let tab = BrowserTab(title: address == "browse://history" ? "History" : "New tab", pages: [Page(address: address)])
        if let linkOpener { linkOpeners[tab.pages[0].id] = linkOpener }
        let insertion = afterCurrent ? session.workspaces[index].tabs.firstIndex { $0.id == previousTabID }.map { $0 + 1 } : nil
        session.workspaces[index].tabs.insert(tab, at: insertion ?? session.workspaces[index].tabs.count)
        select(tab.id)
        pendingAddressEntry = address == "browse://start" ? PendingAddressEntry(tabID: tab.id, paneID: tab.pages[0].id,
            kind: .tab(previousTabID: previousTabID), previousZoom: previousZoom) : nil
        if address == "browse://start" { requestAddress() }
        if closeIfDownload {
            controller(for: tab.pages[0]).onInitialDownload = { [weak self] in
                self?.discardDownloadTab(tab.id, paneID: tab.pages[0].id, previousTabID: previousTabID,
                                         previousZoom: previousZoom)
            }
        }
    }

    private func discardDownloadTab(_ tabID: UUID, paneID: UUID, previousTabID: UUID, previousZoom: UUID?) {
        guard let wi = session.workspaces.firstIndex(where: { $0.tabs.contains { $0.id == tabID } }),
              let ti = session.workspaces[wi].tabs.firstIndex(where: { $0.id == tabID }),
              session.workspaces[wi].tabs[ti].pages.map(\.id) == [paneID],
              !session.workspaces[wi].tabs[ti].isPinned,
              session.workspaces[wi].tabs.count > 1 else { return }
        removeController(paneID)
        session.workspaces[wi].tabs.remove(at: ti)
        if session.selectedTab == tabID {
            let previous = session.workspaces.flatMap(\.tabs).first { $0.id == previousTabID }
            select(previous?.id ?? session.workspaces[wi].tabs[min(ti, session.workspaces[wi].tabs.count - 1)].id)
            if let previousZoom, selectedTab.pages.contains(where: { $0.id == previousZoom }) { zoomedPane = previousZoom }
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
        guard let page = tab.pages.first(where: { $0.id == paneID }), !page.isPinned, page.address == "browse://start",
              (browsers[paneID]?.address ?? "browse://start") == "browse://start" else { return false }
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
        if let sharedStore { sharedStore.recordVisit(url: url, title: title, at: date); return }
        guard history.record(url: url, title: title, at: date) else { return }
        saveHistorySoon()
    }

    func recordHistoryChoice(url: String, query: String) {
        if let sharedStore { sharedStore.recordHistoryChoice(url: url, query: query); return }
        history.recordChoice(url: url, query: query)
        saveHistorySoon()
    }

    func removeHistory(url: String) {
        if let sharedStore { sharedStore.removeHistory(url: url); return }
        history.remove(url: url)
        historyDirty = true
        saveHistory()
    }

    func clearHistory() {
        if let sharedStore { sharedStore.clearHistory(); return }
        history.clear()
        if !historyWritable {
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
        if let sharedStore { sharedStore.saveHistory(); return }
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

    // @lat: [[architecture#Pinned panes and tabs]]
    func isPanePinned(_ id: UUID) -> Bool {
        session.workspaces.flatMap(\.tabs).flatMap(\.pages).first { $0.id == id }?.isPinned == true
    }

    func setPanePinned(_ id: UUID, pinned: Bool) {
        guard let tab = session.workspaces.flatMap(\.tabs).first(where: { $0.pages.contains { $0.id == id } }) else { return }
        editTab(tab.id) { tab in
            if let index = tab.pages.firstIndex(where: { $0.id == id }) { tab.pages[index].isPinned = pinned }
        }
    }

    func setTabPinned(_ id: UUID, pinned: Bool) {
        editTab(id) { tab in
            for index in tab.pages.indices { tab.pages[index].isPinned = pinned }
        }
    }

    func toggleTabPinned(_ id: UUID) {
        guard let tab = session.workspaces.flatMap(\.tabs).first(where: { $0.id == id }) else { return }
        setTabPinned(id, pinned: !tab.isPinned)
    }

    func closeTab(_ id: UUID) {
        guard session.workspaces.flatMap(\.tabs).first(where: { $0.id == id })?.isPinned == false else { return }
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
                if !replacement.isPinned, replacement.pages.count == 1, replacement.pages[0].address == "browse://start",
                   (browsers[replacement.pages[0].id]?.address ?? "browse://start") == "browse://start" {
                    removeController(replacement.pages[0].id)
                    session.workspaces[wi].tabs.remove(at: index)
                }
            }
            session.workspaces[wi].tabs.insert(item.tab, at: min(item.tabIndex, session.workspaces[wi].tabs.count))
        }
        select(item.tab.id)
    }

    func controller(for page: Page) -> PageController {
        if let existing = browsers[page.id] { return existing }
        let extensionURL = URL(string: page.address).flatMap {
            ["webkit-extension", "safari-web-extension"].contains($0.scheme ?? "") ? $0 : nil
        }
        let controller = PageController(address: extensionURL == nil ? page.address : "browse://start", paneID: page.id, websiteSettings: websiteSettings, downloads: downloads, configure: { [weak self] configuration in
            if #available(macOS 15.4, *) { self?.extensions.configure(configuration) }
        })
        bindController(controller, to: page)
        browsers[page.id] = controller
        if #available(macOS 15.4, *), let extensionURL {
            let manager = extensions
            Task { [weak controller] in
                await manager.restorationTask?.value
                guard let controller, manager.store(for: page.id)?.existingController(for: page.id) === controller,
                      controller.address == "browse://start" else { return }
                let extensionURL = manager.restoredExtensionURL(extensionURL)
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

    private func bindController(_ controller: PageController, to page: Page) {
        controller.onFaviconChanged = { [weak self] in
            self?.objectWillChange.send()
            self?.refreshFavoriteIcon(for: page.id)
        }
        mediaPlaybackFocus.register(controller.media)
        mediaCoordinator.register(page.id, controller: controller.media)
        controller.configure = { [weak self] configuration in
            if #available(macOS 15.4, *) { self?.extensions.configure(configuration) }
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
        controller.onNewTab = { [weak self] address in self?.newTab(address: address, afterCurrent: true) }
        controller.onNewPane = { [weak self] address in self?.openPane(address: address, toRightOf: page.id) }
        controller.onNewLink = { [weak self] address, adjacent, mainFrame in
            guard let self else { return }
            switch adjacent ? self.commandClickDestination : .newTab {
            case .newPane: self.openPane(address: address, toRightOf: page.id, fromMainFrame: mainFrame)
            case .dedicatedPane: self.openInDedicatedPane(address: address, from: page.id, fromMainFrame: mainFrame)
            case .newTab: self.newTab(address: address, linkOpener: mainFrame ? page.id : nil, closeIfDownload: true, afterCurrent: true)
            }
        }
        controller.onCommandShiftLink = { [weak self] address, mainFrame in
            guard let self else { return }
            switch self.commandShiftClickDestination {
            case .newTab:
                self.newTab(address: address, linkOpener: mainFrame ? page.id : nil, closeIfDownload: true, afterCurrent: true)
            case .newPane:
                self.openPane(address: address, toRightOf: page.id, fromMainFrame: mainFrame)
            case .newWindow:
                self.onNewLinkWindow?(address)
            }
        }
        controller.onFocus = { [weak self] in self?.focus(page.id) }
        controller.onVisit = { [weak self] url, title in self?.recordVisit(url: url, title: title) }
        controller.onHistoryTitleChanged = { [weak self] url, title in
            guard let self else { return }
            let owner = self.sharedStore ?? self
            owner.history.updateTitle(title, for: url)
            owner.saveHistorySoon()
        }
    }

    func existingController(for pageID: UUID) -> PageController? { browsers[pageID] }

    private func removeController(_ id: UUID) {
        mediaCoordinator.unregister(id)
        let controller = browsers.removeValue(forKey: id)
        controller?.webView.closeInspector()
        controller?.media.detach()
        controller?.webView.pauseAllMediaPlayback(completionHandler: nil)
        controller?.webView.stopLoading()
    }

    // @lat: [[architecture#Cross-window dragging]]
    @discardableResult
    func transfer(tab tabID: UUID, pane paneID: UUID? = nil, to destination: BrowserStore,
                  at placement: WindowDropPlacement) -> Bool {
        guard self !== destination, preferencesStore === destination.preferencesStore,
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
                  blank.pages.count == 1, blank.pages[0].address == "browse://start",
                  (destination.browsers[blank.pages[0].id]?.address ?? "browse://start") == "browse://start" else { return false }
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
            if let controller = browsers[page.id] {
                destination.browsers[page.id] = controller
                destination.bindController(controller, to: page)
            }
            if let opener = linkOpeners[page.id], movedIDs.contains(opener) {
                destination.linkOpeners[page.id] = opener
            }
        }
        if let pendingAddressEntry, movedIDs.contains(pendingAddressEntry.paneID) { self.pendingAddressEntry = nil }
        if let zoomedPane, movedIDs.contains(zoomedPane) { self.zoomedPane = nil }
        destination.zoomedPane = nil
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

    func stopWindow() {
        mediaCoordinator.removeAll()
        save()
        pendingSave?.cancel(); pendingSave = nil
        for page in browsers.values {
            page.webView.closeInspector()
            page.media.detach()
            page.webView.pauseAllMediaPlayback(completionHandler: nil)
            page.webView.stopLoading()
        }
        browsers.removeAll()
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
        if zoomedPane == id { zoomedPane = nil }
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
    func closeInspector() {
        (superview as? WebSurfaceHost)?.removeDeveloperTools()
        inspectorSupport?.invalidate()
        inspectorSupport = nil
    }
    weak var mediaController: PageMediaController?
    var hoveredLink = "" {
        didSet { (superview as? WebSurfaceHost)?.showLinkPreview(hoveredLink) }
    }

    override init(frame: NSRect, configuration: WKWebViewConfiguration) {
        // WebKit defaults this off, including for video players' fullscreen controls.
        configuration.preferences.isElementFullscreenEnabled = true
        LinkHoverObserver.install(in: configuration.userContentController)
        MediaSessionBridge.install(in: configuration.userContentController)
        super.init(frame: frame, configuration: configuration)
        BendInspectorSupport.enable(for: self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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
        hoveredLink = ""
        InputDiagnostics.transition(.webAttachment, window == nil ? .detached : .attached, view: self)
    }
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview == nil { onDialogInvalidated?() }
        hoveredLink = ""
        InputDiagnostics.transition(.webAttachment, superview == nil ? .detached : .attached, view: self, flags: ["superview": true])
    }
}

@MainActor
final class PageController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let downloads: BrowserDownloads
    let media = PageMediaController()
    @Published private(set) var webView: FocusWebView
    var configure: (WKWebViewConfiguration) -> Void
    private var extensionOrigin: URL?
    @Published var address: String
    @Published var title = "New tab"
    @Published var favicon: NSImage? { didSet { onFaviconChanged?() } }
    var onFaviconChanged: (() -> Void)?
    private var faviconTask: Task<Void, Never>?
    private var faviconPageURL: URL?
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
    var onCommandShiftLink: ((String, Bool) -> Void)?
    var onInitialDownload: (() -> Void)?
    var onFocus: (() -> Void)?
    private var observations: [NSKeyValueObservation] = []
    var onVisit: ((String, String) -> Void)?
    var onHistoryTitleChanged: ((String, String) -> Void)?
    private var completedAddress: String?
    private var lastReportedAddress = ""
    private var lastReportedTitle = ""
    private let websiteSettings: WebsiteSettingsStore?
    private var websiteSettingsObservation: AnyCancellable?
    private var zoomURL: URL?
    private var localDocumentDirectory: URL?
    private let externalApplications: ExternalApplicationLinks
    private let javaScriptDialogs: JavaScriptDialogs

    // WebKit's default user agent omits Safari's product tokens. Some sites
    // consequently serve a legacy, fixed-width page to an otherwise modern engine.
    static let websiteApplicationName: String = {
        let safariVersion = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari")
            .flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }
        let version = safariVersion.map { $0.split(separator: ".").prefix(2).joined(separator: ".") } ?? "17.0"
        return "Version/\(version) Safari/605.1.15 Bend/0.1"
    }()

    init(address: String, paneID: UUID? = nil, webView suppliedWebView: FocusWebView? = nil, websiteSettings: WebsiteSettingsStore? = nil,
         externalApplications: ExternalApplicationLinks = .shared, javaScriptDialogs: JavaScriptDialogs = .shared,
         downloads: BrowserDownloads = BrowserDownloads(), configure: @escaping (WKWebViewConfiguration) -> Void = { _ in }) {
        self.address = address
        self.downloads = downloads
        self.externalApplications = externalApplications
        self.javaScriptDialogs = javaScriptDialogs
        self.websiteSettings = websiteSettings
        self.configure = configure
        let configuration = WKWebViewConfiguration()
        configuration.applicationNameForUserAgent = Self.websiteApplicationName
        configuration.websiteDataStore = AppProfile.current.websiteDataStore
        configure(configuration)
        webView = suppliedWebView ?? FocusWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.diagnosticPaneID = paneID
        InputDiagnostics.transition(.webReplacement, .created, view: webView)
        observeWebView()
        navigate(address)
        websiteSettingsObservation = websiteSettings?.$values.sink { [weak self] values in
            guard let self, let url = self.zoomURL, WebsiteSettings.hostname(for: url) != nil else { return }
            self.webView.pageZoom = CGFloat(values.zoom(for: url))
        }
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

    private func observeWebView() {
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
        }
        observations = [
            webView.observe(\.estimatedProgress) { [weak self] _, _ in Task { @MainActor in self?.refresh() } },
            webView.observe(\.isLoading) { [weak self] _, _ in Task { @MainActor in self?.refresh() } },
            webView.observe(\.title) { [weak self] _, _ in Task { @MainActor in self?.refresh() } },
            webView.observe(\.canGoBack) { [weak self] _, _ in Task { @MainActor in self?.refresh() } },
            webView.observe(\.canGoForward) { [weak self] _, _ in Task { @MainActor in self?.refresh() } },
            webView.observe(\.url) { [weak self] _, _ in Task { @MainActor in self?.refresh() } }
        ]
    }

    private func replaceWebView(configuration: WKWebViewConfiguration) {
        InputDiagnostics.transition(.webReplacement, .started, view: webView)
        javaScriptDialogs.cancel(for: webView)
        webView.closeInspector()
        webView.onDialogInvalidated = nil
        observations.removeAll()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.onFocus = nil
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
        onInitialDownload = nil
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
        onInitialDownload = nil
        let localURL = URL(string: input).flatMap { LocalWebDocument.accepts($0) ? $0 : nil }
        guard let url = localURL ?? AddressResolver.resolve(input) else { error = "Enter a web address or search phrase."; return }
        if extensionOrigin != nil {
            extensionOrigin = nil
            let configuration = WKWebViewConfiguration()
            configuration.applicationNameForUserAgent = Self.websiteApplicationName
            configuration.websiteDataStore = AppProfile.current.websiteDataStore
            configure(configuration)
            replaceWebView(configuration: configuration)
        }
        load(url)
    }

    private func load(_ url: URL) {
        javaScriptDialogs.cancel(for: webView)
        webView.hoveredLink = ""
        InputDiagnostics.transition(.webLoad, .requested, view: webView, flags: ["internal": url.scheme == "browse"])
        resetFavicon(for: url)
        error = nil; address = url.absoluteString
        completedAddress = nil
        isStartPage = url.scheme == "browse"
        localDocumentDirectory = url.isFileURL ? url.deletingLastPathComponent() : nil
        // A reused view still displays the outgoing document until commit.
        // Only a fresh view (or native internal page) can take the target zoom now.
        if isStartPage || webView.url == nil { applyWebsiteZoom(for: url) }
        if isStartPage {
            webView.closeInspector()
            webView.stopLoading()
            if webView.url != nil {
                media.detach()
                webView.pauseAllMediaPlayback(completionHandler: nil)
            }
            title = address == "browse://history" ? "History" : (address == "browse://guide" ? "Tiling guide" : "New tab")
            reportNavigation()
        } else {
            if webView.mediaController == nil { media.attach(to: webView) }
            if let localDocumentDirectory { webView.loadFileURL(url, allowingReadAccessTo: localDocumentDirectory) }
            else { webView.load(URLRequest(url: url)) }
        }
    }

    func refresh() {
        defer { onStateChanged?() }
        isLoading = webView.isLoading; progress = webView.estimatedProgress
        canGoBack = webView.canGoBack; canGoForward = webView.canGoForward
        if !isStartPage {
            if let url = webView.url {
                discardFavicon(ifLeaving: url)
                address = url.absoluteString
            }
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
        javaScriptDialogs.cancel(for: webView)
        (webView as? FocusWebView)?.hoveredLink = ""
        (webView.superview as? WebSurfaceHost)?.hideFindBar(restoreFocus: false)
        InputDiagnostics.transition(.webLoad, .started, view: webView)
        resetFavicon(for: webView.url ?? URL(string: address))
        completedAddress = nil
        if !isStartPage { error = nil }
    }
    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        resetFavicon(for: webView.url)
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        onInitialDownload = nil
        discardFavicon(ifLeaving: webView.url)
        javaScriptDialogs.didCommitNavigation(in: webView)
        if webView.url?.isFileURL != true { localDocumentDirectory = nil }
        // The committed URL covers redirects, normal links, and back/forward.
        // Subframe navigation never changes the top-level website's preference.
        if !isStartPage, let url = webView.url { applyWebsiteZoom(for: url) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        InputDiagnostics.transition(.webLoad, .finished, view: webView)
        refresh()
        recordCompletedVisit()
        guard !isStartPage, let url = webView.url else { return }
        faviconTask?.cancel()
        faviconTask = Task { [weak self] in
            let candidates = await FaviconLoader.candidates(in: webView, pageURL: url)
            guard !Task.isCancelled else { return }
            let image = await FaviconLoader.load(candidates, in: webView)
            guard !Task.isCancelled, let self, self.webView === webView,
                  !self.isStartPage, webView.url == url, let image else { return }
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
        if favicon != nil { favicon = nil }
    }

    deinit { faviconTask?.cancel() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { show(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { show(error) }
    func show(_ failure: Error) {
        InputDiagnostics.transition(.webLoad, .cancelled, view: webView)
        completedAddress = nil
        let nativeError = failure as NSError
        // WebKit still uses the legacy policy-interruption error when a
        // navigation becomes a WKDownload. The existing page remains valid.
        let policyInterruption = nativeError.domain == "WebKitErrorDomain" && nativeError.code == 102
        let cancelled = nativeError.domain == NSURLErrorDomain && nativeError.code == NSURLErrorCancelled
        if !cancelled && !policyInterruption { error = failure.localizedDescription }
        refresh()
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        media.reset()
        javaScriptDialogs.cancel(for: webView)
        InputDiagnostics.transition(.webProcessExit, .finished, view: webView)
        error = "This page stopped responding. Reload to continue."
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

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
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
