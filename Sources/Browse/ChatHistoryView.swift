import SwiftUI
import BrowseCore

private typealias ChatHistoryState<Value> = SwiftUI.State<Value>

struct ChatHistoryView: View {
    let store: BrowserStore
    @ObservedObject var history: ChatHistoryStore
    @ChatHistoryState private var query = ""
    @ChatHistoryState private var deleting: SavedChat?
    @ChatHistoryState private var previewing: SavedChat?

    private var matches: [SavedChat] {
        history.records.filter { record in
            query.isEmpty || ([record.title, record.preview] + record.tab.pages.map(\.address) + record.bubbles.map(\.text))
                .contains { $0.localizedStandardContains(query) }
        }
    }
    private var days: [Date] { Set(matches.map { Calendar.current.startOfDay(for: $0.updatedAt) }).sorted(by: >) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Label("AI Chat History", systemImage: "bubble.left.and.bubble.right")
                    .font(.system(size: 28, weight: .semibold))
                Text("Pick up where you left off. Restore a conversation and its panes in a new tab.")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search conversations and pages", text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                }
            }.padding(12).background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            if let error = history.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            if store.isPrivate {
                ContentUnavailableView("AI is unavailable in private windows", systemImage: "lock")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if matches.isEmpty {
                ContentUnavailableView(query.isEmpty ? "No chats yet" : "No matching conversations",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text(query.isEmpty ? "Your conversations will be saved here automatically." : "Try a phrase from a message or a page address."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(days, id: \.self) { day in
                            Text(dayTitle(day)).font(.headline).foregroundStyle(.secondary).padding(.top, 8)
                            ForEach(matches.filter { Calendar.current.isDate($0.updatedAt, inSameDayAs: day) }) { record in
                                card(record)
                            }
                        }
                    }.padding(.bottom, 12)
                }
            }
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .confirmationDialog("Delete this conversation?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete Chat", role: .destructive) { if let deleting { history.remove([deleting.id]) }; deleting = nil }
        } message: { Text("This also clears any open copy of this conversation. Your browser panes stay open.") }
        .sheet(item: $previewing) { record in
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(record.title).font(.headline).lineLimit(2)
                    Spacer()
                    Button("Done") { previewing = nil }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(record.bubbles.filter { $0.kind == .text }) { bubble in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(bubble.isUser ? "You" : "Assistant").font(.caption).foregroundStyle(.secondary)
                                if bubble.isUser {
                                    Text(bubble.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                } else { ChatMarkdown(source: bubble.text) }
                            }.padding(14).background(.primary.opacity(bubble.isUser ? 0.08 : 0.04), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                HStack { Spacer(); Button("Restore Chat and Panes") { previewing = nil; store.restoreChat(record) }.buttonStyle(.borderedProminent) }
            }.padding(24).frame(minWidth: 480, idealWidth: 620, minHeight: 400, idealHeight: 640)
                .environment(\.openURL, OpenURLAction { url in
                    previewing = nil
                    store.restoreChat(record)
                    var address = url.absoluteString
                    for (old, new) in zip(record.tab.pages, store.selectedTab.pages) {
                        address = address.replacingOccurrences(of: old.id.uuidString, with: new.id.uuidString, options: .caseInsensitive)
                    }
                    if let destination = URL(string: address), let chat = store.chats[store.selectedTab.id] {
                        Task { await chat.openLink(destination) }
                    }
                    return .handled
                })
        }
    }

    private func card(_ record: SavedChat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                Button { previewing = record } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(record.title).font(.system(size: 16, weight: .semibold)).lineLimit(2)
                        if !record.preview.isEmpty { Text(ChatMarkdownDocument.render(record.preview).string).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2) }
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
                Button { store.restoreChat(record) } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
                    .help("Restore messages and pane layout in a new tab")
            }
            HStack(spacing: 8) {
                Image(systemName: "rectangle.split.2x1")
                Text("\(record.tab.pages.count) \(record.tab.pages.count == 1 ? "pane" : "panes")")
                Text("·")
                Text(record.tab.pages.compactMap { AddressResolver.nativePageTitle($0.address) ?? URL(string: $0.address)?.host }.joined(separator: ", ")).lineLimit(1)
                Spacer(minLength: 8)
                Text(record.updatedAt.formatted(date: .omitted, time: .shortened))
                Button { deleting = record } label: { Image(systemName: "trash") }.buttonStyle(.plain).help("Delete chat")
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(18).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.07)))
    }
    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .abbreviated, time: .omitted)
    }
}
