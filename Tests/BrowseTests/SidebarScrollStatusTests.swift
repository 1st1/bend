import AppKit
import Testing
import BrowseCore
@testable import Browse

// @lat: [[lat.md/tests/sidebar-tests#Sidebar overflow counts]]
@Test func sidebarOverflowCounts() {
    // Five rows occupy 6...40, 47...81, 88...122, 129...163, 170...204.
    func status(_ top: CGFloat, _ bottom: CGFloat, count: Int = 5, inset: CGFloat = 6) -> SidebarScrollStatus {
        SidebarScrollStatus(visibleRect: CGRect(x: 0, y: top, width: 240, height: bottom - top),
                            tabCount: count, topInset: inset)
    }
    #expect(status(0, 122).above == 0)
    #expect(status(0, 122).below == 2)
    #expect(status(81, 163).above == 2)
    #expect(status(81, 163).below == 1)
    // Even a half-point of visible row keeps it out of the hidden count.
    #expect(status(80.5, 170.5).above == 1)
    #expect(status(80.5, 170.5).below == 0)
    #expect(status(81, 170).below == 1)
    #expect(status(81, 163, count: 7).below == 3)
    #expect(status(81, 163, count: 3).below == 0)
    #expect(status(81, 250).below == 0)
    #expect(status(81, 163, inset: 16).above == 1)
    #expect(status(81, 163, inset: 16).below == 1)
    #expect(status(-20, 250).above == 0)
    #expect(status(-20, 250).below == 0)
    #expect(status(250, 350).above == 5)
    // Tabs behind the floating media player count as hidden.
    let covered = SidebarScrollStatus(visibleRect: CGRect(x: 0, y: 0, width: 240, height: 250),
        tabCount: 5, topInset: 6, bottomOcclusion: 128)
    #expect(covered.below == 2 && covered.above == 0)
    let toolbar = SidebarScrollStatus(visibleRect: CGRect(x: 0, y: 81, width: 240, height: 134),
        tabCount: 5, topInset: 58, topOcclusion: 52)
    #expect(toolbar.above == 2 && toolbar.below == 1)
    #expect(status(0, 0) == SidebarScrollStatus())
    #expect(status(0, 100, count: 0) == SidebarScrollStatus())
}

// @lat: [[lat.md/tests/sidebar-tests#Sidebar toolbar fade]]
@Test(arguments: [false, true], SidebarSide.allCases) @MainActor
func sidebarToolbarFade(floating: Bool, side: SidebarSide) async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("SidebarFade-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let owner = BrowserWindows(root: root, persistentExtensions: false)
    owner.restore(show: false)
    let browser = try #require(owner.active)
    let store = browser.store
    store.onAddressRequested = nil
    defer { owner.prepareToQuit(); browser.window.close() }
    store.sidebarSide = side
    store.sidebarVisible = !floating
    store.sidebarFloating = floating
    for _ in 0..<25 { store.newTab(inBackground: true) }
    let host = try #require(browser.window.contentView)
    func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants($0, of: type) }
    }
    func settle() async throws {
        for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
    }
    try await settle()
    let scroll = try #require(descendants(host, of: NSScrollView.self).first { abs($0.bounds.width - store.sidebarWidth) < 1 })
    let viewport = scroll.convert(scroll.bounds, to: nil)
    let top = host.convert(host.bounds, to: nil).maxY - (floating ? FloatingSidebarTrackingView.inset : 0)
    #expect(viewport.maxY >= top - 1 && viewport.maxY <= top + (floating ? FloatingSidebarTrackingView.inset : 0) + 1)
    let first = try #require(descendants(host, of: TabDragSourceView.self).first { $0.tabID == store.sidebarTabs.first?.id })
    let headerHeight = 2 * (Chrome.headerCenterY - (floating ? FloatingSidebarTrackingView.inset : 0))
    #expect(abs(top - first.convert(first.bounds, to: nil).maxY - headerHeight - ToolbarScrollFade.contentInset) <= 1)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 50))
    scroll.reflectScrolledClipView(scroll.contentView)
    try await settle()
    #expect(first.convert(first.bounds, to: nil).maxY > viewport.maxY - headerHeight)
    // Adding a fixed favorites row must restore top clearance without shrinking the viewport.
    let favorite = try #require(store.addFavorite(store.selectedTab.id, address: "https://favorite.example"))
    try await settle()
    scroll.contentView.scroll(to: .zero)
    scroll.reflectScrolledClipView(scroll.contentView)
    try await settle()
    let next = try #require(descendants(host, of: TabDragSourceView.self).first { $0.tabID == store.sidebarTabs.first?.id })
    #expect(scroll.convert(scroll.bounds, to: nil) == viewport)
    #expect(viewport.maxY - next.convert(next.bounds, to: nil).maxY >= headerHeight + 44 + ToolbarScrollFade.contentInset)
    store.removeFavorite(favorite)
}
