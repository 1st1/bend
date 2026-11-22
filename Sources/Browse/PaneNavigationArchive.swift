import Foundation

/// One file per pane lets a restored window load its navigation lists on demand.
struct PaneNavigationArchive {
    let directory: URL

    init(sessionFile: URL) {
        directory = sessionFile.deletingPathExtension().appendingPathExtension("navigation")
    }

    private struct Record: Codable {
        let address: String
        let interactionState: Data
        let closeHistoryURL: URL?
    }

    @MainActor
    func read(_ id: UUID) -> PaneRestorationState? {
        let file = directory.appendingPathComponent(id.uuidString)
        guard let data = try? Data(contentsOf: file),
              let record = try? PropertyListDecoder().decode(Record.self, from: data) else { return nil }
        return PaneRestorationState(interactionState: record.interactionState, snapshot: nil,
                                    address: record.address, title: "", zoom: 1, closeHistoryURL: record.closeHistoryURL)
    }

    @MainActor
    func write(_ state: PaneRestorationState?, for id: UUID) throws {
        guard let state, let bytes = state.interactionState as? Data else {
            try remove(id)
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let record = Record(address: state.address, interactionState: bytes, closeHistoryURL: state.closeHistoryURL)
        let file = directory.appendingPathComponent(id.uuidString)
        try PropertyListEncoder().encode(record).write(to: file, options: .atomic)
    }

    func remove(_ id: UUID) throws {
        try removeIfPresent(directory.appendingPathComponent(id.uuidString))
    }

    func clear() throws { try removeIfPresent(directory) }

    private func removeIfPresent(_ url: URL) throws {
        do { try FileManager.default.removeItem(at: url) }
        catch CocoaError.fileNoSuchFile { }
    }
}
