import SwiftUI
import BrowseCore

private typealias HistoryState<Value> = SwiftUI.State<Value>

// @lat: [[architecture#History interface]]
struct HistoryView: View {
    @ObservedObject var store: BrowserStore
    let navigate: (String) -> Void
    @HistoryState<String> private var query = ""
    @HistoryState<Bool> private var confirmingClear = false
    @FocusState private var searching: Bool

    private var days: [(date: Date, visits: [HistoryVisit])] {
        Dictionary(grouping: store.history.matching(query), by: { Calendar.current.startOfDay(for: $0.date) })
            .map { (date: $0.key, visits: $0.value) }.sorted { $0.date > $1.date }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("History").font(.system(size: 28, weight: .semibold))
                Spacer()
                Button("Clear History…") { confirmingClear = true }
                    .disabled(store.history.visits.isEmpty && store.historyError == nil)
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search titles and addresses", text: $query)
                    .textFieldStyle(.plain).focused($searching)
                    .accessibilityLabel("Search browsing history")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel("Clear history search")
                }
            }.padding(12).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            if let error = store.historyError {
                Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.orange)
            }
            if days.isEmpty {
                ContentUnavailableView(query.isEmpty ? "No history yet" : "No matching pages", systemImage: "clock",
                    description: Text(query.isEmpty ? "Pages you visit will appear here." : "Try a page title or part of its address."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(days, id: \.date) { day in
                            Text(dayTitle(day.date)).font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary).padding(.top, 10)
                            ForEach(day.visits) { visit in
                                HStack(spacing: 12) {
                                    Text(visit.date.formatted(date: .omitted, time: .shortened))
                                        .font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
                                    Button { navigate(visit.url) } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(visit.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                            Text(visit.url).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                        .contextMenu {
                                            Button("Open in New Tab") { store.newTab(address: visit.url) }
                                            Button("Remove Page from History", role: .destructive) { store.removeHistory(url: visit.url) }
                                        }
                                    Button { store.removeHistory(url: visit.url) } label: { Image(systemName: "trash") }
                                        .buttonStyle(.plain).foregroundStyle(.secondary)
                                        .help("Remove this page from history")
                                        .accessibilityLabel("Remove \(visit.title) from history")
                                }.padding(.vertical, 9)
                                Divider().opacity(0.25)
                            }
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { searching = true }
        .confirmationDialog("Clear all browsing history?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { store.clearHistory() }
        } message: {
            Text("This removes your recorded visits and history suggestions. Open pages and website data stay intact.")
        }
    }

    private func dayTitle(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
