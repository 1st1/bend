import SwiftUI
import BrowseCore

private typealias MediaViewState<Value> = SwiftUI.State<Value>

struct SidebarMediaPlayer: View {
    @ObservedObject var coordinator: WindowMediaCoordinator
    @ObservedObject var store: BrowserStore
    @MediaViewState<Bool> private var showsVolume = false

    var body: some View {
        if let source = coordinator.selected {
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    Button { store.revealPage(source.paneID) } label: {
                        HStack(spacing: 7) {
                            if let page = store.existingController(for: source.paneID) {
                                SidebarMediaIcon(page: page)
                            } else { Image(systemName: "music.note").frame(width: 14, height: 14) }
                            Text(source.state.title)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.9))
                                .lineLimit(1).truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).help(source.state.title + " — Show playing pane")
                    Button { coordinator.dismiss() } label: { Image(systemName: "xmark") }
                        .buttonStyle(ChromeButtonStyle()).help("Dismiss player")
                }
                .padding(.horizontal, store.sidebarWidth < 140 ? 6 : 12)
                .frame(height: Chrome.paneHeaderHeight)
                .background(PaneChromeBackground(cornerRadius: 12, roundsBottomCorners: false,
                                                appearance: store.paneHeaderGlass))
                VStack(alignment: .leading, spacing: 7) {
                    Text(source.state.artist.isEmpty ? source.state.site : "\(source.state.artist) · \(source.state.site)")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .center)
                    SidebarMediaProgress(source: source, timeline: source.state.timeline, coordinator: coordinator)
                        .id(source.id + ":" + source.state.playerID)
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        control("backward.end.fill", action: "previoustrack", help: "Previous track", source: source)
                        control(source.state.playing ? "pause.fill" : "play.fill",
                                action: source.state.playing ? "pause" : "play",
                                help: source.state.playing ? "Pause" : "Play", source: source)
                        control("forward.end.fill", action: "nexttrack", help: "Next track", source: source)
                        Spacer(minLength: 0)
                    }.frame(maxWidth: .infinity)
                    .overlay(alignment: .leading) {
                        if store.sidebarWidth >= 180 { sourcePicker(source) }
                    }
                    .overlay(alignment: .trailing) {
                        if store.sidebarWidth >= 180 && source.state.actions.contains("volume") {
                            Button { showsVolume.toggle() } label: {
                                Image(systemName: source.state.volume == 0 ? "speaker.slash" : "speaker.wave.2")
                            }.buttonStyle(ChromeButtonStyle()).help("Volume")
                                .popover(isPresented: $showsVolume) {
                                    Slider(value: Binding(get: { coordinator.selected?.state.volume ?? 1 },
                                        set: { value in Task { await coordinator.send("volume", to: source, value: value) } }), in: 0...1)
                                        .frame(width: 120).padding(12).accessibilityLabel("Media volume")
                                }
                        }
                    }
                    if store.sidebarWidth < 180 { sourcePicker(source) }
                    if let error = coordinator.commandError {
                        Text(error).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
                    }
                }
                .padding(store.sidebarWidth < 140 ? 6 : 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(PaneChromeBackground(cornerRadius: 12, roundsTopCorners: false))
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .background(WindowDragArea(excluded: true))
            // The pane canvas supplies the six-point gap on the right.
            .padding(.leading, PaneGeometry.gap)
            .padding(.vertical, PaneGeometry.gap)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Now playing")
        }
    }

    @ViewBuilder private func sourcePicker(_ selected: SidebarMediaSource) -> some View {
        if let next = coordinator.sources.first(where: { $0.id != selected.id }) {
            Menu {
                ForEach(coordinator.sources) { item in
                    Button("\(item.state.title) — \(item.state.site)") {
                        coordinator.select(item)
                        store.revealPage(item.paneID)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    HStack(spacing: 3) {
                        sourceIcon(selected)
                        sourceIcon(next)
                    }
                    .fixedSize()
                    .frame(width: 25, alignment: .leading)
                    .mask(LinearGradient(stops: [
                        .init(color: .white, location: 0),
                        .init(color: .white, location: 0.6),
                        .init(color: .clear, location: 1)
                    ], startPoint: .leading, endPoint: .trailing))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .frame(height: 24)
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .foregroundStyle(.white.opacity(0.7))
            .fixedSize()
            .help("Switch player (\(coordinator.sources.count) players)")
            .accessibilityLabel("\(coordinator.sources.count) players")
            .accessibilityValue(selected.state.title)
        }
    }

    @ViewBuilder private func sourceIcon(_ source: SidebarMediaSource) -> some View {
        if let page = store.existingController(for: source.paneID) {
            SidebarMediaIcon(page: page)
        } else {
            Image(systemName: "music.note").frame(width: 14, height: 14)
        }
    }

    private func control(_ symbol: String, action: String, help: String, source: SidebarMediaSource) -> some View {
        Button { Task { await coordinator.send(action, to: source) } } label: { Image(systemName: symbol) }
            .buttonStyle(ChromeButtonStyle())
            .disabled(!source.state.actions.contains(action)).help(help).accessibilityLabel(help)
    }
}

private struct SidebarMediaProgress: View {
    let source: SidebarMediaSource
    let timeline: MediaTimeline?
    let coordinator: WindowMediaCoordinator
    @MediaViewState<Double?> private var scrubPosition: Double?

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.25, paused: (timeline?.rate ?? 0) == 0 || scrubPosition != nil)) { _ in
            let position = timeline.map { min($0.duration, scrubPosition ?? $0.position()) } ?? 0
            VStack(spacing: 2) {
                if let timeline, source.state.actions.contains("seekto") {
                    MediaProgressSlider(value: Binding(get: { position }, set: { scrubPosition = $0 }), duration: timeline.duration) { editing in
                        if editing { scrubPosition = position }
                        else if let target = scrubPosition {
                            scrubPosition = nil
                            Task { await coordinator.send("seekto", to: source, value: target) }
                        }
                    }
                    .frame(height: 16)
                    .accessibilityLabel("Playback position")
                    .accessibilityValue("\(time(position)) of \(time(timeline.duration))")
                    .help("Seek")
                } else {
                    MediaProgressSlider(value: .constant(position), duration: timeline?.duration ?? 1, seekable: false) { _ in }
                        .frame(height: 16)
                        .accessibilityLabel("Playback progress")
                        .accessibilityValue(timeline.map { "\(time(position)) of \(time($0.duration))" } ?? "Timing unavailable")
                }
                HStack {
                    Text(timeline == nil ? "—" : time(position))
                    Spacer(minLength: 4)
                    Text(timeline.map { time($0.duration) } ?? "—")
                }
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .onChange(of: source.state.title) { _, _ in scrubPosition = nil }
        .onChange(of: timeline?.duration) { _, _ in scrubPosition = nil }
    }

    private func time(_ value: Double) -> String {
        guard value.isFinite, value >= 0, value < Double(Int.max) else { return "—" }
        let seconds = Int(value)
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct SidebarMediaIcon: View {
    @ObservedObject var page: PageController
    var body: some View {
        if let image = page.favicon {
            Image(nsImage: image).resizable().scaledToFit().frame(width: 14, height: 14)
        } else { Image(systemName: "music.note").frame(width: 14, height: 14) }
    }
}
