import AppKit
import SwiftUI
import Testing
import BrowseCore
@testable import Browse

// @lat: [[tests#Favorite tabs and persistence]]
@Test @MainActor func favoriteTabsAndPersistence() throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendFavorites-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("session.json")
    let store = BrowserStore(sessionFile: file, persistentExtensions: false)
    #expect(!store.canFavorite(store.selectedTab))
    store.newTab(address: "https://example.com/inbox")
    let original = store.selectedTab
    let id = try #require(store.addFavorite(original.id))
    #expect(store.favorites.count == 1)
    #expect(store.addFavorite(original.id) == id)
    #expect(!store.sidebarTabs.contains { $0.id == original.id })
    #expect(store.existingController(for: original.focusedPane) == nil)
    store.editTab(original.id) { $0.pages[0].address = "https://example.com/message/42" }
    store.newTab(address: "browse://guide")
    store.openFavorite(id)
    #expect(store.selectedTab.id == original.id)
    #expect(store.selectedTab.pages[0].address == "https://example.com/message/42")
    #expect(store.favorites[0].address == "https://example.com/inbox")
    store.save()
    let restored = BrowserStore(sessionFile: file, persistentExtensions: false)
    #expect(restored.favorites.map(\.id) == [id])
    restored.openFavorite(id)
    #expect(restored.selectedTab.id == original.id)
    #expect(restored.existingController(for: original.focusedPane) == nil)
    restored.closeTab(original.id)
    #expect(restored.favorites.count == 1)
    restored.openFavorite(id)
    #expect(restored.selectedTab.id != original.id)
    #expect(restored.selectedTab.pages[0].address == "https://example.com/inbox")
    let reopened = restored.selectedTab.id
    restored.openFavorite(id)
    #expect(restored.selectedTab.id == reopened)
    restored.removeFavorite(id)
    #expect(restored.favorites.isEmpty)
    #expect(restored.sidebarTabs.contains { $0.id == reopened })

    // Duplicate URLs share one tile, and the right-clicked tab becomes its target.
    store.newTab(address: "https://example.com/inbox")
    let duplicate = store.selectedTab.id
    #expect(store.addFavorite(duplicate) == id)
    #expect(store.favoriteTarget(id)?.tab.id == duplicate)
    #expect(store.sidebarTabs.contains { $0.id == original.id })
    for i in 1..<SidebarFavorite.limit {
        store.newTab(address: "https://example.com/\(i)")
        #expect(store.addFavorite(store.selectedTab.id) != nil)
    }
    store.newTab(address: "https://example.com/tenth")
    #expect(!store.canFavorite(store.selectedTab))
    #expect(store.addFavorite(store.selectedTab.id) == nil)
    #expect(store.favorites.count == 9)
    store.removeFavorite(id)
    #expect(store.addFavorite(store.selectedTab.id) != nil)
    for address in ["browse://history", "file:///tmp/page.html", "javascript:alert(1)", "https://user:secret@example.com/"] {
        store.newTab(address: address)
        #expect(!store.canFavorite(store.selectedTab))
    }
    #expect(store.session.isValid)
    let legacy = Data("{\"id\":\"\(UUID())\",\"address\":\"browse://start\"}".utf8)
    #expect(try JSONDecoder().decode(Page.self, from: legacy).favoriteID == nil)
    var oldSession = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(BrowserSession())) as? [String: Any])
    oldSession.removeValue(forKey: "favorites")
    #expect(try JSONDecoder().decode(BrowserSession.self, from: JSONSerialization.data(withJSONObject: oldSession)).favorites == nil)
}

// @lat: [[tests#Shared favorites and pane transfers]]
@Test @MainActor func sharedFavoritesAndTransfers() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendFavoriteWindows-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let main = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    let other = BrowserStore(sessionFile: root.appendingPathComponent("Windows/other.json"), sharedStore: main)
    other.newTab(address: "https://example.com/")
    let id = try #require(other.addFavorite(other.selectedTab.id))
    #expect(main.favorites.map(\.id) == [id])
    let source = other.selectedTab
    #expect(other.transfer(tab: source.id, to: main, at: .workspace(main.session.workspaces[0].id)))
    main.openFavorite(id)
    #expect(main.selectedTab.id == source.id)
    #expect(!main.sidebarTabs.contains { $0.id == source.id })
    main.split(.horizontal)
    #expect(!main.sidebarTabs.contains { $0.id == source.id })
    main.openFavorite(id)
    #expect(main.selectedTab.focusedPane == source.focusedPane)
    #expect(main.selectedTab.pages.count == 2)
    // Each window reuses its own live favorite; another window can open its own.
    other.openFavorite(id)
    let otherTab = other.selectedTab.id
    other.openFavorite(id)
    #expect(other.selectedTab.id == otherTab)
    #expect(otherTab != source.id)
    main.save(); other.save()
    let restoredMain = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    let restoredOther = BrowserStore(sessionFile: root.appendingPathComponent("Windows/other.json"), sharedStore: restoredMain)
    #expect(restoredOther.favorites.map(\.id) == [id])
    restoredOther.openFavorite(id)
    #expect(restoredOther.selectedTab.id == otherTab)
    restoredMain.removeFavorite(id)
    #expect(restoredOther.favorites.isEmpty)
    #expect(restoredOther.sidebarTabs.contains { $0.id == otherTab })
}

// @lat: [[tests#Favorite favicon snapshots]]
@Test @MainActor func favoriteFaviconSnapshots() throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendFavoriteIcons-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("session.json")
    let store = BrowserStore(sessionFile: file, persistentExtensions: false)
    let page = store.selectedTab.pages[0]
    let controller = store.controller(for: page)
    controller.address = "https://example.com/"
    controller.onNavigation?(controller.address, "Example")
    store.focus(page.id)
    let id = try #require(store.addFavorite(store.selectedTab.id))
    #expect(store.favorites[0].iconPNG == nil)
    let icon = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
        NSColor.systemBlue.setFill(); NSBezierPath(ovalIn: rect).fill(); return true
    }
    controller.favicon = icon
    let saved = try #require(store.favorites[0].iconPNG)
    #expect(NSImage(data: saved) != nil)
    controller.address = "https://other.example/"
    controller.favicon = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
        NSColor.systemRed.setFill(); NSBezierPath(rect: rect).fill(); return true
    }
    #expect(store.favorites[0].iconPNG == saved)
    store.save()
    let restored = BrowserStore(sessionFile: file, persistentExtensions: false)
    #expect(restored.favorites.first?.iconPNG == saved)
    #expect(restored.favoriteTarget(id) != nil)
    #expect(restored.existingController(for: page.id) == nil)
    let invalid = SidebarFavorite(address: "file:///tmp/icon", title: "Invalid")
    let oversized = SidebarFavorite(address: "https://example.org/", title: "Large", iconPNG: Data(count: 65_537))
    #expect(SidebarFavorite.validated([invalid, oversized] + restored.favorites + restored.favorites).count == 1)
}

// @lat: [[tests#Favorite tile interaction]]
@Test @MainActor func favoriteTileInteraction() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendFavoriteTiles-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    for i in 0..<9 {
        store.newTab(address: "https://example.com/\(i)")
        store.editTab { $0.title = "Favorite \(i + 1)" }
        store.addFavorite(store.selectedTab.id)
    }
    let window = BrowseWindow(contentRect: NSRect(x: -10000, y: -10000, width: 240, height: 240),
                              styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.browserStore = store
    window.appearance = NSAppearance(named: .darkAqua)
    let host = NSHostingView(rootView: VStack {
        SidebarFavorites(store: store)
        Spacer(minLength: 0)
    }.padding(10).frame(width: 240, height: 240)
        .background(Color(red: 0.13, green: 0.12, blue: 0.19)).overlay(WindowDragArea()))
    window.contentView = host
    window.orderFront(nil)
    defer { window.close() }
    func settle() async throws {
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(40)) }
    }
    func markers(_ view: NSView) -> [WindowDragAreaView] {
        (view as? WindowDragAreaView).map { [$0] } ?? view.subviews.flatMap(markers)
    }
    try await settle()
    let tiles = markers(host).filter { $0.excluded && $0.bounds.height > 40 }
    try #require(tiles.count == 9)
    let frames = tiles.map { host.convert($0.bounds, from: $0) }
    #expect(Set(frames.map { Int($0.midY.rounded()) }).count == 3)
    #expect(Set(frames.map { Int($0.midX.rounded()) }).count == 3)
    #expect(frames.allSatisfy { $0.width >= 60 && $0.height == 44 })
    let tile = tiles[0]
    let point = tile.convert(NSPoint(x: tile.bounds.midX, y: tile.bounds.midY), to: nil)
    #expect(WindowDragAreaView.find(at: point, in: window) == nil)
    try sendPaneMouse(.leftMouseDown, at: point, to: window)
    try sendPaneMouse(.leftMouseUp, at: point, to: window)
    try await settle()
    #expect(store.selectedTab.pages[0].favoriteID == store.favorites[0].id)
    #expect(store.sidebarTabs.count == 1) // Only the initial guide tab remains.
    if let path = ProcessInfo.processInfo.environment["BEND_FAVORITES_SNAPSHOT"],
       let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
