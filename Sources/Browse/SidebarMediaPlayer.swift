import SwiftUI

private typealias MediaViewState<Value> = SwiftUI.State<Value>

struct SidebarMediaPlayer: View {
    @ObservedObject var coordinator: WindowMediaCoordinator
    let store: BrowserStore
    @MediaViewState<Bool> private var showsVolume = false

    var body: some View {
        if let source = coordinator.selected {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top, spacing: 2) {
                    Button { store.revealPage(source.paneID) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(source.state.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                            Text(source.state.artist.isEmpty ? source.state.site : "\(source.state.artist) · \(source.state.site)")
                                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).help("Show playing pane")
                    Button { coordinator.dismiss() } label: { Image(systemName: "xmark") }
                        .buttonStyle(ChromeButtonStyle()).help("Dismiss player")
                }
                HStack(spacing: 0) {
                    if store.sidebarWidth >= 180 {
                        if let page = store.existingController(for: source.paneID) {
                            SidebarMediaIcon(page: page)
                        } else { Image(systemName: "music.note").frame(width: 16, height: 16) }
                        Spacer(minLength: 2)
                    }
                    control("backward.end.fill", action: "previoustrack", help: "Previous track", source: source)
                    control(source.state.playing ? "pause.fill" : "play.fill",
                            action: source.state.playing ? "pause" : "play",
                            help: source.state.playing ? "Pause" : "Play", source: source)
                    control("forward.end.fill", action: "nexttrack", help: "Next track", source: source)
                    if store.sidebarWidth >= 180 {
                        Spacer(minLength: 2)
                        if source.state.actions.contains("volume") {
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
                }.frame(maxWidth: .infinity)
                if coordinator.sources.count > 1 {
                    Menu {
                        ForEach(coordinator.sources) { item in
                            Button("\(item.state.title) — \(item.state.site)") { coordinator.select(item) }
                        }
                    } label: { Label("\(coordinator.sources.count) players", systemImage: "music.note.list").font(.system(size: 10)) }
                    .menuStyle(.borderlessButton)
                }
                if let error = coordinator.commandError {
                    Text(error).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .padding(store.sidebarWidth < 140 ? 6 : 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.06)) }
            .background(WindowDragArea(excluded: true))
            .padding(.horizontal, store.sidebarWidth < 140 ? 4 : 8).padding(.vertical, 8)
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
            Image(nsImage: image).resizable().scaledToFit().frame(width: 16, height: 16)
        } else { Image(systemName: "music.note").frame(width: 16, height: 16) }
    }
}
