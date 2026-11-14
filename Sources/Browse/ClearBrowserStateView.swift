import SwiftUI
import WebKit

private typealias ClearState<Value> = SwiftUI.State<Value>

enum BrowserStateRange: String, CaseIterable, Identifiable {
    case all = "All", hour = "Last hour", day = "Last 24 hours", week = "Last 7 days", month = "Last 30 days"
    var id: Self { self }
    func cutoff(now: Date = Date()) -> Date {
        switch self {
        case .all: .distantPast
        case .hour: now.addingTimeInterval(-3600)
        case .day: now.addingTimeInterval(-86400)
        case .week: now.addingTimeInterval(-7 * 86400)
        case .month: now.addingTimeInterval(-30 * 86400)
        }
    }
}

// @lat: [[lat.md/architecture/privacy#Clearing browser state]]
struct ClearBrowserStateView: View {
    let store: BrowserStore
    @ClearState private var history = false
    @ClearState private var chats = false
    @ClearState private var cache = false
    @ClearState private var downloads = false
    @ClearState private var siteData = false
    @ClearState private var closeWindows = false
    @ClearState private var historyRange: BrowserStateRange = .all
    @ClearState private var chatRange: BrowserStateRange = .all
    @ClearState private var confirming = false
    @ClearState private var clearing = false
    @ClearState private var result: String?
    @ClearState private var failed = false

    static let cacheTypes: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache,
        WKWebsiteDataTypeOfflineWebApplicationCache, WKWebsiteDataTypeFetchCache]
    static var siteDataTypes: Set<String> { WKWebsiteDataStore.allWebsiteDataTypes().subtracting(cacheTypes) }

    var body: some View {
        Section("Clear browser state") {
            rangeRow("Clear history", enabled: $history, range: $historyRange)
            rangeRow("Clear AI chats", enabled: $chats, range: $chatRange)
            Toggle("Clear download history", isOn: $downloads).toggleStyle(.checkbox)
            Text("Downloaded files and active transfers are kept.").font(.caption).foregroundStyle(.secondary)
            Toggle("Clear cache", isOn: $cache).toggleStyle(.checkbox)
            Toggle("Clear cookies, localStorage, and other website data", isOn: $siteData).toggleStyle(.checkbox)
            Toggle("Close all open tabs and windows", isOn: $closeWindows).toggleStyle(.checkbox)
                .disabled(store.preferencesStore.onCloseAllWindows == nil)
            Text("Chat ranges use the conversation’s last activity. Cache and website data are cleared for all time. Removing website data may sign you out of websites.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(clearing ? "Clearing…" : "Clear Selected Data…", role: .destructive) { confirming = true }
                    .disabled(clearing || !(history || chats || downloads || cache || siteData || closeWindows))
                Button("Select Everything") {
                    history = true; chats = true; downloads = true; cache = true; siteData = true
                    closeWindows = store.preferencesStore.onCloseAllWindows != nil
                }
                .disabled(history && chats && downloads && cache && siteData && (closeWindows || store.preferencesStore.onCloseAllWindows == nil))
                if clearing { ProgressView().controlSize(.small) }
            }
            if let result { Text(result).font(.caption).foregroundStyle(failed ? Color.orange : Color.secondary).textSelection(.enabled) }
        }
        .disabled(clearing)
        .confirmationDialog("Clear selected browser data?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Clear Selected Data", role: .destructive) { Task { await clear() } }
        } message: {
            Text(summary + "\n\nThis cannot be undone. Clearing chats also removes their messages from open chat panels." + (closeWindows ? " All browser windows, including private windows and pinned tabs, will close and will not be restored on restart." : " Browser panes remain open."))
        }
    }
    private var summary: String {
        var items: [String] = []
        if history { items.append("History: " + historyRange.rawValue) }
        if chats { items.append("AI chats: " + chatRange.rawValue) }
        if downloads { items.append("Download history: All finished transfers (files are kept)") }
        if cache { items.append("Cache: All") }
        if siteData { items.append("Cookies and website data: All") }
        if closeWindows { items.append("Close all browser tabs and windows, including pinned tabs") }
        return items.joined(separator: "\n")
    }
    private func rangeRow(_ title: String, enabled: Binding<Bool>, range: Binding<BrowserStateRange>) -> some View {
        HStack {
            Toggle(title, isOn: enabled).toggleStyle(.checkbox)
            Spacer()
            Picker("Time range for " + title, selection: range) {
                ForEach(BrowserStateRange.allCases) { Text($0.rawValue).tag($0) }
            }.labelsHidden().frame(width: 160).disabled(!enabled.wrappedValue)
        }
    }
    @MainActor private func clear() async {
        clearing = true; result = nil; failed = false
        defer { clearing = false }
        let now = Date()
        var errors: [String] = []
        if closeWindows {
            do { try store.preferencesStore.onCloseAllWindows?() }
            catch { errors.append(error.localizedDescription) }
        }
        if history {
            store.clearHistory(since: historyRange.cutoff(now: now))
            if let error = store.historyError { errors.append(error) }
        }
        if chats, !store.chatHistory.clear(since: chatRange.cutoff(now: now)) {
            errors.append(store.chatHistory.error ?? "AI chats could not be cleared.")
        }
        if downloads {
            store.downloads.clearFinished()
            if let error = store.downloads.persistenceError { errors.append(error) }
        }
        var types: Set<String> = []
        if cache { types.formUnion(Self.cacheTypes); store.faviconCache?.clear() }
        if siteData { types.formUnion(Self.siteDataTypes) }
        if !types.isEmpty { await store.websiteDataStore.removeData(ofTypes: types, modifiedSince: .distantPast) }
        failed = !errors.isEmpty
        result = errors.isEmpty ? "Selected browser data cleared." : errors.joined(separator: "\n")
    }
}
