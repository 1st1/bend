import SwiftUI
import BrowseCore

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
                        Button("Duplicate tab") { store.duplicateTab(target.tab.id) }
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
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        private var shape: RoundedRectangle {
            RoundedRectangle(cornerRadius: Chrome.sidebarItemCornerRadius)
        }

        var body: some View {
            configuration.label
                .background {
                    shape.fill(ChromeButtonStyle.highlightBackground)
                        .opacity(selected ? 0 : 1)
                }
                .modifier(TabSelectionMaterial(selected: selected, shape: shape))
                .contentShape(shape)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: selected)
        }
    }
}
