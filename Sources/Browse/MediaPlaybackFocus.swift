import Foundation

// @lat: [[lat.md/architecture/media#Exclusive media playback]]
@MainActor
final class MediaPlaybackFocus {
    private struct Entry { weak var controller: PageMediaController? }
    private var entries: [ObjectIdentifier: Entry] = [:]
    private weak var owner: PageMediaController?
    private var revision = 0

    func register(_ controller: PageMediaController) {
        guard controller.playbackFocus !== self else { return }
        controller.playbackFocus = self
        entries[ObjectIdentifier(controller)] = Entry(controller: controller)
        if controller.sessions.contains(where: \.playing) { claim(controller) }
    }

    func claim(_ controller: PageMediaController) {
        revision += 1
        let ticket = revision
        owner = controller
        entries = entries.filter { $0.value.controller != nil }
        for entry in entries.values {
            guard let other = entry.controller, other !== controller,
                  other.playbackFocus === self, other.sessions.contains(where: \.playing) else { continue }
            let states = other.sessions.filter(\.playing)
            Task { @MainActor [weak self, weak other] in
                guard let self, let other else { return }
                await other.pauseForFocusLoss(states) { [weak self, weak other] in
                    guard let self, let other else { return false }
                    return self.revision == ticket && self.owner !== other && other.playbackFocus === self
                }
            }
        }
    }
}
