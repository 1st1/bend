import AppKit
import BrowseCore

// @lat: [[architecture#Sidebar favorites]]
extension BrowserStore {
    var favorites: [SidebarFavorite] { preferencesStore.session.favorites ?? [] }

    var sidebarTabs: [BrowserTab] {
        session.workspaces.flatMap(\.tabs).filter { tab in
            !tab.pages.contains { page in
                guard let id = page.favoriteID else { return false }
                return favoriteTarget(id)?.tab.id == tab.id
            }
        }
    }

    func favoritePage(in tab: BrowserTab) -> Page? {
        tab.pages.first { $0.id == tab.focusedPane }
    }

    func favorite(for tab: BrowserTab) -> SidebarFavorite? {
        guard let page = favoritePage(in: tab) else { return nil }
        return favorites.first { $0.id == page.favoriteID }
    }

    func canFavorite(_ tab: BrowserTab) -> Bool {
        guard let page = favoritePage(in: tab), favorite(for: tab) == nil,
              SidebarFavorite.websiteURL(page.address) != nil else { return false }
        return favorites.count < SidebarFavorite.limit || favorites.contains { $0.address == page.address }
    }

    @discardableResult
    func addFavorite(_ tabID: UUID) -> UUID? {
        guard let tab = session.workspaces.flatMap(\.tabs).first(where: { $0.id == tabID }),
              let page = favoritePage(in: tab) else { return nil }
        if let existing = favorite(for: tab) { return existing.id }
        guard canFavorite(tab) else { return nil }
        let favorite: SidebarFavorite
        if let existing = favorites.first(where: { $0.address == page.address }) {
            favorite = existing
        } else {
            let pageTitle = existingController(for: page.id)?.title ?? tab.title
            let title = pageTitle.isEmpty || pageTitle == "New tab" ? URL(string: page.address)?.host ?? page.address : pageTitle
            favorite = SidebarFavorite(address: page.address, title: title)
            preferencesStore.session.favorites = favorites + [favorite]
            preferencesStore.saveSoon()
        }
        associateFavorite(favorite.id, with: page.id)
        refreshFavoriteIcon(for: page.id)
        return favorite.id
    }

    func removeFavorite(_ id: UUID) {
        preferencesStore.session.favorites = favorites.filter { $0.id != id }
        preferencesStore.saveSoon()
        // Old pane associations are harmless: only IDs in the shared favorites
        // collection are treated as favorites, including in other open windows.
    }

    func favoriteTarget(_ id: UUID) -> (tab: BrowserTab, page: Page)? {
        guard let favorite = favorites.first(where: { $0.id == id }) else { return nil }
        let tabs = session.workspaces.flatMap(\.tabs)
        for tab in tabs {
            if let page = tab.pages.first(where: { $0.favoriteID == id }) { return (tab, page) }
        }
        for tab in tabs {
            if let page = tab.pages.first(where: { $0.address == favorite.address }) { return (tab, page) }
        }
        return nil
    }

    func openFavorite(_ id: UUID) {
        guard let favorite = favorites.first(where: { $0.id == id }) else { return }
        if let target = favoriteTarget(id) {
            associateFavorite(id, with: target.page.id)
            select(target.tab.id)
            focus(target.page.id)
        } else {
            newTab(address: favorite.address)
            editTab { tab in
                tab.title = favorite.title
                tab.pages[0].favoriteID = id
            }
        }
    }

    private func associateFavorite(_ id: UUID, with pageID: UUID) {
        for tab in session.workspaces.flatMap(\.tabs) where tab.pages.contains(where: { $0.id == pageID || $0.favoriteID == id }) {
            editTab(tab.id) { tab in
                for index in tab.pages.indices {
                    if tab.pages[index].id == pageID { tab.pages[index].favoriteID = id }
                    else if tab.pages[index].favoriteID == id { tab.pages[index].favoriteID = nil }
                }
            }
        }
    }

    func refreshFavoriteIcon(for pageID: UUID) {
        guard let page = session.workspaces.flatMap(\.tabs).flatMap(\.pages).first(where: { $0.id == pageID }),
              let index = favorites.firstIndex(where: { $0.id == page.favoriteID }),
              let controller = existingController(for: pageID),
              FaviconLoader.sameOrigin(URL(string: controller.address), URL(string: favorites[index].address)),
              let image = controller.favicon, let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff), bitmap.pixelsWide <= 128, bitmap.pixelsHigh <= 128,
              let data = bitmap.representation(using: .png, properties: [:]), data.count <= 65_536,
              data != favorites[index].iconPNG else { return }
        preferencesStore.session.favorites?[index].iconPNG = data
        preferencesStore.saveSoon()
    }
}
