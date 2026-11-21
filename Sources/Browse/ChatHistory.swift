import AI
import Foundation
import Combine
import BrowseCore

struct SavedChat: Codable, Identifiable {
    var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var tab: BrowserTab
    var bubbles: [ChatBubble]
    var modelID: String
    var modelTuning: [String: ModelTuning]?
    var draft: String
    var thinkingSummary: String
    var thinkingSummaryBeforeBubbleID: UUID?
    var title: String { bubbles.first(where: \.isUser)?.text ?? "New chat" }
    var preview: String { bubbles.last(where: { !$0.isUser && $0.kind == .text })?.text ?? draft }
}

// @lat: [[lat.md/architecture/ai#Saved chat history]]
@MainActor final class ChatHistoryStore: ObservableObject {
    @Published private(set) var records: [SavedChat] = []
    @Published private(set) var error: String?
    let clearRequests = PassthroughSubject<Date, Never>()
    let deletions = PassthroughSubject<Set<UUID>, Never>()
    private var deleted: Set<UUID> = []
    private let directory: URL?

    init(directory: URL?) {
        self.directory = directory
        guard let directory, FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
                do {
                    let record = try JSONDecoder().decode(SavedChat.self, from: Data(contentsOf: file))
                    var session = BrowserSession()
                    session.workspaces = [Workspace(name: "Tabs", tabs: [record.tab])]
                    session.selectedTab = record.tab.id
                    guard session.isValid else { throw CocoaError(.fileReadCorruptFile) }
                    records.append(record)
                } catch { self.error = "Some saved chats could not be read. Their files have been preserved." }
            }
            records.sort { $0.updatedAt > $1.updatedAt }
        } catch { self.error = "Chat history could not be read: \(error.localizedDescription)" }
    }

    func save(_ record: SavedChat) {
        guard let directory, !deleted.contains(record.id) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent(record.id.uuidString + ".json")
            try JSONEncoder().encode(record).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            records.removeAll { $0.id == record.id }
            records.append(record)
            records.sort { $0.updatedAt > $1.updatedAt }
        } catch { self.error = "Chat history could not be saved: \(error.localizedDescription)" }
    }

    func reportInvalidLayout() {
        error = "This conversation could not be reopened because its saved pane layout is invalid."
    }

    @discardableResult func remove(_ ids: Set<UUID>) -> Bool {
        deleted.formUnion(ids)
        deletions.send(ids)
        var success = true
        for id in ids {
            do {
                if let file = directory?.appendingPathComponent(id.uuidString + ".json"), FileManager.default.fileExists(atPath: file.path) {
                    try FileManager.default.removeItem(at: file)
                }
                records.removeAll { $0.id == id }
            } catch { self.error = "Chat history could not be cleared: \(error.localizedDescription)"; success = false }
        }
        return success
    }

    @discardableResult func clear(since cutoff: Date) -> Bool {
        clearRequests.send(cutoff)
        let success = remove(Set(records.filter { $0.updatedAt >= cutoff }.map(\.id)))
        guard cutoff == .distantPast, success else { return success }
        do {
            if let directory, FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
            error = nil
            return true
        } catch { self.error = "Chat history could not be cleared: \(error.localizedDescription)"; return false }
    }
}

extension BrowserStore {
    func showChatHistory() {
        guard !isPrivate else { return }
        for tab in session.workspaces.flatMap(\.tabs) {
            if let page = tab.pages.first(where: { $0.address == "bend://chats" }) { select(tab.id); focus(page.id); return }
        }
        newTab(address: "bend://chats")
    }

    func restoreChat(_ record: SavedChat) {
        guard !isPrivate else { return }
        // New pane identities keep an archived layout independent of every live tab.
        guard record.tab.hasValidLayout else { chatHistory.reportInvalidLayout(); return }
        var restored = record
        var mapping = [UUID: UUID]()
        for i in restored.tab.pages.indices {
            let old = restored.tab.pages[i].id
            let new = UUID()
            mapping[old] = new
            restored.tab.pages[i].id = new
        }
        guard let layout = record.tab.layout.remappingPanes(mapping),
              let focus = mapping[record.tab.focusedPane] else { chatHistory.reportInvalidLayout(); return }
        restored.tab.id = UUID()
        restored.tab.layout = layout
        restored.tab.focusedPane = focus
        restored.tab.commandClickPaneID = record.tab.commandClickPaneID.flatMap { mapping[$0] }
        func remap(_ text: String) -> String {
            mapping.reduce(text) { $0.replacingOccurrences(of: $1.key.uuidString, with: $1.value.uuidString, options: .caseInsensitive) }
        }
        for i in restored.bubbles.indices {
            restored.bubbles[i].text = remap(restored.bubbles[i].text)
            restored.bubbles[i].detail = remap(restored.bubbles[i].detail)
        }
        // Continuing a restored conversation creates an independent history entry.
        restored.id = UUID()
        session.workspaces[0].tabs.append(restored.tab)
        session.selectedTab = restored.tab.id
        let chat = TabChat(store: self, tabID: restored.tab.id)
        chat.restore(restored)
        chats[restored.tab.id] = chat
        openChats.insert(restored.tab.id)
        chat.persist()
        saveSoon()
    }
}
