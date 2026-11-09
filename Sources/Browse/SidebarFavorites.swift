import SwiftUI
import BrowseCore

private typealias FavoriteState<Value> = SwiftUI.State<Value>

// @lat: [[architecture#Sidebar favorites]]
struct SidebarFavorites: View {
    @ObservedObject var store: BrowserStore

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 3), spacing: 7) {
            ForEach(store.favorites) { favorite in
                let target = store.favoriteTarget(favorite.id)
                let selected = target?.tab.id == store.session.selectedTab && target?.page.id == store.selectedTab.focusedPane
                Button { store.openFavorite(favorite.id) } label: {
                    Group {
                        if let data = favorite.iconPNG, let image = NSImage(data: data) {
                            Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                        } else {
                            Text(String((URL(string: favorite.address)?.host ?? favorite.title).prefix(1)).uppercased())
                                .font(.system(size: 17, weight: .medium)).foregroundStyle(.secondary)
                        }
                    }.frame(width: 20, height: 20).accessibilityHidden(true)
                        .frame(maxWidth: .infinity).frame(height: 44)
                }
                .buttonStyle(FavoriteTileStyle(selected: selected))
                .help("\(favorite.title)\n\(favorite.googleAccountEmail ?? favorite.address)")
                .accessibilityLabel(favorite.googleAccountEmail.map { "\(favorite.title), \($0)" } ?? favorite.title)
                .accessibilityValue(selected ? "Selected" : "")
                .accessibilityIdentifier("favorite-\(favorite.id)")
                .background(WindowDragArea(excluded: true))
                .contextMenu {
                    if GoogleFavoriteService(address: favorite.address) != nil {
                        Button("Google Account…") { store.customizeFavorite(favorite.id) }
                    }
                    Button("Remove from Favorites") { store.removeFavorite(favorite.id) }
                    if let target {
                        Button("Close tab") { store.closeTab(target.tab.id) }.disabled(target.tab.isPinned)
                    }
                }
            }
        }
    }
}

private struct FavoriteTileStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        Tile(configuration: configuration, selected: selected)
    }

    private struct Tile: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        @FavoriteState<Bool> private var hovered = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.white.opacity(configuration.isPressed ? 0.2 : selected ? 0.15 : hovered ? 0.11 : 0.06))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.white.opacity(selected ? 0.16 : 0.04), lineWidth: 0.5)
                        .allowsHitTesting(false)
                }
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onHover { hovered = $0 }
                .onDisappear { hovered = false }
                .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in hovered = false }
                .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in hovered = false }
        }
    }
}
