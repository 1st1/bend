import AppKit
import Combine
import WebKit

struct MediaTimeline: Equatable {
    let duration: Double
    let position: Double
    let rate: Double
    let updatedAt: TimeInterval

    init?(_ raw: Any?, playing: Bool, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard let values = raw as? [String: Any],
              let duration = values["duration"] as? Double, duration.isFinite, duration > 0,
              let position = values["position"] as? Double, position.isFinite, (0...duration).contains(position),
              let rate = values["rate"] as? Double, rate.isFinite else { return nil }
        self.duration = duration; self.position = position
        self.rate = playing ? rate : 0; updatedAt = now
    }

    func position(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Double {
        min(duration, max(0, position + max(0, now - updatedAt) * rate))
    }
}

struct MediaSessionState: Equatable, Identifiable {
    let id: String
    let playerID: String
    let title: String
    let artist: String
    let site: String
    let playing: Bool
    let playbackRevision: Int
    let actions: Set<String>
    let volume: Double?
    let timeline: MediaTimeline?
}

@MainActor
final class PageMediaController: ObservableObject {
    weak var playbackFocus: MediaPlaybackFocus?
    @Published private(set) var sessions: [MediaSessionState] = []
    private weak var webView: FocusWebView?
    private var frames: [String: WKFrameInfo] = [:]
    private var mainDocument: String?
    private var refreshTask: Task<Void, Never>?
    private var generation = 0
    private static let actions: Set<String> = ["play", "pause", "previoustrack", "nexttrack", "volume", "seekto"]

    func attach(to web: FocusWebView) {
        webView?.mediaController = nil
        reset()
        webView = web
        web.mediaController = self
    }

    func reset() {
        generation += 1
        refreshTask?.cancel(); refreshTask = nil
        frames.removeAll(); mainDocument = nil
        if !sessions.isEmpty { sessions = [] }
    }

    func detach() {
        webView?.mediaController = nil
        webView = nil
        reset()
    }

    private func remove(_ id: String) {
        frames.removeValue(forKey: id)
        if sessions.contains(where: { $0.id == id }) { sessions.removeAll { $0.id == id } }
        if sessions.isEmpty { refreshTask?.cancel(); refreshTask = nil }
    }

    func receive(_ message: WKScriptMessage) {
        guard message.webView === webView,
              let body = message.body as? [String: Any], let id = body["documentID"] as? String,
              UUID(uuidString: id) != nil, let kind = body["kind"] as? String else { return }
        if kind == "hello" {
            if message.frameInfo.isMainFrame, mainDocument != id {
                reset(); mainDocument = id
            }
            return
        }
        if kind == "gone" { remove(id); return }
        guard kind == "state", let active = body["active"] as? Bool else { return }
        if message.frameInfo.isMainFrame, let mainDocument, mainDocument != id { return }
        if !active { remove(id); return }
        guard frames[id] != nil || frames.count < 32,
              let playerID = body["playerID"] as? String, !playerID.isEmpty, playerID.count < 64,
              let playing = body["playing"] as? Bool, let playbackRevision = body["playbackRevision"] as? Int,
              playbackRevision >= 0, let rawActions = body["actions"] as? [String],
              rawActions.count <= 32 else { return }
        let origin = message.frameInfo.securityOrigin
        let site = origin.host.isEmpty ? (message.frameInfo.isMainFrame ? (webView?.url?.host ?? "Local media") : "Embedded media") : origin.host
        let title = Self.clean(body["title"])
        let volume = (body["volume"] as? NSNumber)?.doubleValue
        let state = MediaSessionState(id: id, playerID: playerID,
            title: title.isEmpty ? site : title, artist: Self.clean(body["artist"]), site: site,
            playing: playing, playbackRevision: playbackRevision, actions: Set(rawActions).intersection(Self.actions),
            volume: volume.flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil },
            timeline: MediaTimeline(body["timeline"], playing: playing))
        frames[id] = message.frameInfo
        let previous = sessions.first { $0.id == id }
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            if sessions[index] != state { sessions[index] = state }
        } else { sessions.append(state) }
        if state.playing && (previous?.playing != true || previous?.playbackRevision != state.playbackRevision) {
            playbackFocus?.claim(self)
        }
        startRefreshing()
    }

    func pauseForFocusLoss(_ states: [MediaSessionState], stillCurrent: () -> Bool) async {
        guard let webView else { return }
        let epoch = generation
        for state in states {
            guard stillCurrent(), generation == epoch else { return }
            guard let frame = frames[state.id] else { continue }
            // The document checks the playback revision too: a queued pause must
            // not stop a newer play that hasn't reached native code yet.
            let handled = await evaluate("""
                const result = window.__bendMedia?.pauseForFocusLoss(documentID, playerID, revision);
                return result === 'paused' || result === 'stale';
                """, arguments: ["documentID": state.id, "playerID": state.playerID, "revision": state.playbackRevision],
                frame: frame, web: webView, timeout: .seconds(2))
            guard stillCurrent(), generation == epoch else { return }
            if !handled {
                // Covers Web Audio/closed-root players with no usable handler.
                webView.pauseAllMediaPlayback(completionHandler: nil)
                _ = await evaluate("return window.__bendMedia?.pauseForFocusLoss(documentID, playerID, revision, true) === 'paused'",
                    arguments: ["documentID": state.id, "playerID": state.playerID, "revision": state.playbackRevision],
                    frame: frame, web: webView, timeout: .seconds(2))
            }
        }
    }

    static func clean(_ raw: Any?) -> String {
        guard let text = raw as? String else { return "" }
        let scalars = text.prefix(512).unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) &&
            ![0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
              0x2066, 0x2067, 0x2068, 0x2069].contains($0.value)
        }
        return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func startRefreshing() {
        guard refreshTask == nil, !sessions.isEmpty else { return }
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self else { return }
                await self.refresh()
            }
        }
    }

    func refresh() async {
        guard let webView else { return }
        let epoch = generation
        for (id, frame) in frames {
            let valid = await evaluate(
                "return window.__bendMedia?.refresh(documentID) ?? false",
                arguments: ["documentID": id], frame: frame, web: webView, timeout: .seconds(2))
            guard generation == epoch else { return }
            if !valid { remove(id) }
        }
    }

    func send(_ action: String, to state: MediaSessionState, value: Double = 0) async -> Bool {
        guard Self.actions.contains(action), state.actions.contains(action), value.isFinite,
              sessions.contains(where: { $0.id == state.id && $0.playerID == state.playerID }),
              let frame = frames[state.id], let webView else { return false }
        if action == "seekto" {
            guard let timeline = state.timeline, (0...timeline.duration).contains(value) else { return false }
        }
        let epoch = generation
        let result = await evaluate(
            "return await window.__bendMedia?.command(documentID, playerID, action, value) ?? false",
            arguments: ["documentID": state.id, "playerID": state.playerID, "action": action, "value": value],
            frame: frame, web: webView, timeout: .seconds(5))
        return generation == epoch && result
    }

    private func evaluate(_ script: String, arguments: [String: Any], frame: WKFrameInfo,
                          web: WKWebView, timeout: Duration) async -> Bool {
        await withCheckedContinuation { continuation in
            let completion = MediaEvaluationCompletion(continuation)
            completion.timeout = Task { @MainActor in
                do { try await Task.sleep(for: timeout) } catch { return }
                completion.finish(false)
            }
            web.callAsyncJavaScript(script, arguments: arguments, in: frame, in: .page) { result in
                completion.finish((try? result.get()) as? Bool == true)
            }
        }
    }
}

@MainActor
private final class MediaEvaluationCompletion {
    private var continuation: CheckedContinuation<Bool, Never>?
    var timeout: Task<Void, Never>?
    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
    func finish(_ value: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel(); timeout = nil
        continuation.resume(returning: value)
    }
}
