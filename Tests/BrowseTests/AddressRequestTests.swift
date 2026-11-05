import Foundation
import AppKit
import Testing
import BrowseCore
@testable import Browse

// @lat: [[tests#Location popup requests]]
@Test @MainActor func locationPopupRequests() {
    let file = FileManager.default.temporaryDirectory
        .appendingPathComponent("BrowseTests-\(UUID())/session.json")
    let store = BrowserStore(sessionFile: file)
    var requested: [UUID] = []
    store.onAddressRequested = { requested.append($0) }

    let original = store.selectedTab.focusedPane
    store.requestAddress()
    #expect(requested == [original])

    for axis in [BrowseCore.SplitAxis.horizontal, .vertical] {
        store.split(axis)
        #expect(requested.last == store.selectedTab.focusedPane)
        #expect(store.selectedTab.focusedPane != original)
    }
    #expect(requested.count == 3)
    store.requestAddress(for: original)
    #expect(store.selectedTab.focusedPane == original)
    #expect(requested.last == original)
    store.requestAddress(for: UUID())
    #expect(requested.count == 4)

    store.newTab()
    #expect(requested.count == 5)
    #expect(requested.last == store.selectedTab.focusedPane)
    // Closing the final tab creates one replacement and requests its address.
    for tab in store.session.workspaces.flatMap(\.tabs) { store.closeTab(tab.id) }
    #expect(requested.count == 6)
    #expect(requested.last == store.selectedTab.focusedPane)

    let count = requested.count
    store.openPane(address: "https://example.com", toRightOf: store.selectedTab.focusedPane)
    store.newTab(address: "https://example.com/another")
    #expect(requested.count == count)
}

// @lat: [[tests#UI preference persistence]]
@Test @MainActor func uiPreferencePersistence() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BrowsePreferences-\(UUID())")
    let file = directory.appendingPathComponent("session.json")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // Legacy sessions omit the optional preference keys.
    let legacy = BrowserSession()
    try JSONEncoder().encode(legacy).write(to: file)
    let store = BrowserStore(sessionFile: file, persistentExtensions: false)
    #expect(store.selectedTab.id == legacy.selectedTab)
    #expect(!store.commandClickOpensNewTab)
    #expect(store.inactivePaneDimAmount == 0.08)
    #expect(store.windowGlass == .windowDefault)
    #expect(store.paneHeaderGlass == .headerDefault)
    store.commandClickOpensNewTab = true
    store.inactivePaneDimAmount = 0.35
    store.windowGlass = GlassAppearance(clear: true, tint: .init(red: 0.2, green: 0.4, blue: 0.8), darkening: 0.15)
    store.paneHeaderGlass = GlassAppearance(tint: .init(red: 0.8, green: 0.3, blue: 0.1), darkening: 0.65)
    store.save()
    #expect(store.persistenceError == nil)
    let restored = BrowserStore(sessionFile: file, persistentExtensions: false)
    #expect(restored.commandClickOpensNewTab)
    #expect(restored.inactivePaneDimAmount == 0.35)
    #expect(restored.windowGlass == store.windowGlass)
    #expect(restored.paneHeaderGlass == store.paneHeaderGlass)
    #expect(restored.selectedTab.id == legacy.selectedTab)
    store.inactivePaneDimAmount = -1
    #expect(store.inactivePaneDimAmount == 0)
    store.inactivePaneDimAmount = 2
    #expect(store.inactivePaneDimAmount == 1)
    store.inactivePaneDimAmount = .nan
    #expect(store.inactivePaneDimAmount == 1)
    store.session.inactivePaneDimAmount = -2
    #expect(store.inactivePaneDimAmount == 0)
    store.session.inactivePaneDimAmount = .infinity
    #expect(store.inactivePaneDimAmount == 0.08)
    store.windowGlass = GlassAppearance(tint: .init(red: -1, green: 2, blue: 0.5), darkening: 2)
    #expect(store.windowGlass.darkening == 1)
    #expect(store.windowGlass.tint == .init(red: 0, green: 1, blue: 0.5))
    store.paneHeaderGlass = GlassAppearance(tint: .init(red: .nan, green: 0, blue: 0), darkening: .infinity)
    #expect(store.paneHeaderGlass == .headerDefault)
    store.windowGlass = .windowDefault
    store.paneHeaderGlass = .headerDefault
    store.inactivePaneDimAmount = 0.08
    store.save()
    #expect(store.persistenceError == nil)
    let reset = BrowserStore(sessionFile: file, persistentExtensions: false)
    #expect(reset.windowGlass == .windowDefault)
    #expect(reset.paneHeaderGlass == .headerDefault)
}

// @lat: [[tests#Live window glass preferences]]
@Test @MainActor func liveWindowGlassPreferences() throws {
    guard #available(macOS 26.0, *) else { return }
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseGlass-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = BrowserStore(sessionFile: directory.appendingPathComponent("session.json"), persistentExtensions: false)
    let content = NSView()
    let glass = BrowserWindowGlass(store: store, content: content)
    #expect(glass.style == .regular)
    #expect(glass.tintColor == nil)
    store.windowGlass = GlassAppearance(clear: true, tint: .init(red: 0.1, green: 0.4, blue: 0.8))
    #expect(glass.style == .clear)
    let tint = try #require(glass.tintColor?.usingColorSpace(.sRGB))
    #expect(abs(tint.blueComponent - 0.8) < 0.001)
    store.paneHeaderGlass = GlassAppearance(darkening: 0.9)
    #expect(glass.style == .clear)
    #expect(glass.contentView === content)
    store.windowGlass = .windowDefault
    #expect(glass.style == .regular)
    #expect(glass.tintColor == nil)
    #expect(glass.contentView === content)
}
