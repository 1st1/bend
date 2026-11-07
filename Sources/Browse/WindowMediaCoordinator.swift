import Combine
import Foundation

struct SidebarMediaSource: Identifiable, Equatable {
    let paneID: UUID
    let state: MediaSessionState
    var id: String { "\(paneID):\(state.id)" }
}

@MainActor
final class WindowMediaCoordinator: ObservableObject {
    @Published private(set) var sources: [SidebarMediaSource] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var commandError: String?
    private struct Registration {
        weak var controller: PageMediaController?
        let subscription: AnyCancellable
    }
    private var registrations: [UUID: Registration] = [:]
    private var started: [String: UInt64] = [:]
    private var dismissed: Set<String> = []
    private var sequence: UInt64 = 0
    private var chosenID: String?

    var selected: SidebarMediaSource? { sources.first { $0.id == selectedID } }

    func register(_ paneID: UUID, controller: PageMediaController) {
        guard registrations[paneID]?.controller !== controller else { return }
        unregister(paneID)
        let subscription = controller.$sessions.sink { [weak self] states in self?.update(paneID, states: states) }
        registrations[paneID] = Registration(controller: controller, subscription: subscription)
    }

    func unregister(_ paneID: UUID) {
        registrations.removeValue(forKey: paneID)
        update(paneID, states: [])
    }

    func removeAll() {
        registrations.removeAll(); sources = []; selectedID = nil
        started.removeAll(); dismissed.removeAll(); chosenID = nil; commandError = nil
    }

    private func update(_ paneID: UUID, states: [MediaSessionState]) {
        let old = Dictionary(uniqueKeysWithValues: sources.filter { $0.paneID == paneID }.map { ($0.id, $0) })
        let incoming = states.map { SidebarMediaSource(paneID: paneID, state: $0) }
        for item in incoming {
            let previous = old[item.id]?.state
            if started[item.id] == nil || (item.state.playing &&
                (previous?.playing != true || previous?.playbackRevision != item.state.playbackRevision)) {
                sequence += 1; started[item.id] = sequence; dismissed.remove(item.id)
                if item.state.playing { chosenID = nil }
            }
        }
        let next = sources.filter { $0.paneID != paneID } + incoming
        if next != sources { sources = next }
        let ids = Set(sources.map(\.id))
        started = started.filter { ids.contains($0.key) }
        dismissed.formIntersection(ids)
        if let chosenID, !ids.contains(chosenID) { self.chosenID = nil }
        choose()
    }

    private func choose() {
        let available = sources.filter { !dismissed.contains($0.id) }
        let next = available.first { $0.id == chosenID } ?? available.max {
            if $0.state.playing != $1.state.playing { return !$0.state.playing }
            return (started[$0.id] ?? 0) < (started[$1.id] ?? 0)
        }
        if selectedID != next?.id { selectedID = next?.id; commandError = nil }
    }

    func select(_ source: SidebarMediaSource) {
        guard sources.contains(where: { $0.id == source.id }) else { return }
        chosenID = source.id; dismissed.remove(source.id); choose()
    }

    func dismiss() {
        guard let selectedID else { return }
        dismissed.insert(selectedID); chosenID = nil; choose()
    }

    func send(_ action: String, to target: SidebarMediaSource? = nil, value: Double = 0) async {
        guard let source = target ?? selected, let controller = registrations[source.paneID]?.controller else { return }
        let success = await controller.send(action, to: source.state, value: value)
        guard selectedID == source.id else { return }
        commandError = success ? nil : "Couldn’t control this player. Open its tab to continue."
    }
}
