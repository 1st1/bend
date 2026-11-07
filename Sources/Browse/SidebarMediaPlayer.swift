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
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        control("backward.end.fill", action: "previoustrack", help: "Previous track", source: source)
                        control(source.state.playing ? "pause.fill" : "play.fill",
                                action: source.state.playing ? "pause" : "play",
                                help: source.state.playing ? "Pause" : "Play", source: source)
                        control("forward.end.fill", action: "nexttrack", help: "Next track", source: source)
                        Spacer(minLength: 0)
                    }.frame(maxWidth: .infinity)
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
                    if coordinator.sources.count > 1 {
                        Menu {
                            ForEach(coordinator.sources) { item in
                                Button("\(item.state.title) — \(item.state.site)") {
                                    coordinator.select(item)
                                    store.revealPage(item.paneID)
                                }
                            }
                        } label: { Label("\(coordinator.sources.count) players", systemImage: "music.note.list").font(.system(size: 10)) }
                        .menuStyle(.borderlessButton)
                        .foregroundStyle(.white.opacity(0.7))
                        .fixedSize()
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
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

    private func control(_ symbol: String, action: String, help: String, source: SidebarMediaSource) -> some View {
        Button { Task { await coordinator.send(action, to: source) } } label: { Image(systemName: symbol) }
            .buttonStyle(ChromeButtonStyle())
            .disabled(!source.state.actions.contains(action)).help(help).accessibilityLabel(help)
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
