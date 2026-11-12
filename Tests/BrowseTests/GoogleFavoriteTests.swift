import AppKit
import SwiftUI
import Testing
import BrowseCore
@testable import Browse

// @lat: [[lat.md/tests/favorites-tests#Google favorite account URLs]]
@Test func googleFavoriteAccountURLs() throws {
    let email = try #require(GoogleFavoriteService.normalizedEmail(" Person+Work@Example.com \n"))
    #expect(email == "person+work@example.com")
    for service in GoogleFavoriteService.allCases {
        #expect(GoogleFavoriteService(address: service.home) == service)
        let address = service.accountAddress(email: email)
        #expect(!address.contains("+"))
        let account = try #require(URLComponents(string: address))
        #expect(account.queryItems == [URLQueryItem(name: "authuser", value: email)])
        let launch = try #require(URLComponents(string: service.launchAddress(email: email)))
        #expect(launch.host == "accounts.google.com" && launch.path == "/AccountChooser")
        #expect(launch.queryItems?.first { $0.name == "Email" }?.value == email)
        #expect(launch.queryItems?.first { $0.name == "continue" }?.value == address)
        #expect(GoogleFavoriteService.suggestedEmail(address: address) == email)
    }
    for address in ["https://mail.google.com.evil.test/", "https://google.com/", "file://mail.google.com/mail/",
                    "https://user:password@drive.google.com/", "https://calendar.google.com:8443/"] {
        #expect(GoogleFavoriteService(address: address) == nil)
    }
    for email in ["", "name", "name@@example.com", "a b@example.com", "a@-example.com", "a@example..com", "a@example.com?other=1", "a\nb@example.com"] {
        #expect(GoogleFavoriteService.normalizedEmail(email) == nil)
    }
    #expect(GoogleFavoriteService.suggestedEmail(address: "https://mail.google.com/mail/?authuser=2") == nil)
    let legacy = SidebarFavorite(address: "https://example.com/", title: "Example")
    #expect(try JSONDecoder().decode(SidebarFavorite.self, from: JSONEncoder().encode(legacy)).googleAccountEmail == nil)
}

// @lat: [[lat.md/tests/favorites-tests#Google favorite customization lifecycle]]
@Test @MainActor func googleFavoriteCustomizationLifecycle() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendGoogleFavorites-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("session.json")
    let store = BrowserStore(sessionFile: file, persistentExtensions: false)
    for service in GoogleFavoriteService.allCases {
        store.newTab(address: service.home + "u/2/")
        let tab = store.selectedTab
        store.requestFavorite(tab.id)
        let request = try #require(store.favoriteCustomization)
        #expect(request.service == service && request.email.isEmpty)
        let count = store.favorites.count
        #expect(store.saveFavoriteCustomization(request, email: "not an email") != nil)
        #expect(store.favorites.count == count && store.favoriteCustomization != nil)
        store.favoriteCustomization = nil // Cancel is non-mutating; stale submit is ignored.
        #expect(store.saveFavoriteCustomization(request, email: "person@example.com") != nil)
        #expect(store.favorites.count == count)
        store.requestFavorite(tab.id)
        let active = try #require(store.favoriteCustomization)
        #expect(store.saveFavoriteCustomization(active, email: " Person+Work@Example.com ") == nil)
        let favorite = try #require(store.favorites.last)
        #expect(favorite.googleAccountEmail == "person+work@example.com")
        #expect(favorite.address == service.accountAddress(email: "person+work@example.com"))
        #expect(store.selectedTab.pages[0].address == favorite.launchAddress)
        #expect(store.existingController(for: tab.focusedPane) == nil)
        #expect(!store.sidebarTabs.contains { $0.id == tab.id })
        // Google redirects to an account index. Keep that live document until restart.
        store.editTab(tab.id) { $0.pages[0].address = service.home + "u/4/" }
        store.openFavorite(favorite.id)
        #expect(store.selectedTab.pages[0].address == service.home + "u/4/")
    }
    store.save()
    let restored = BrowserStore(sessionFile: file, persistentExtensions: false)
    for favorite in restored.favorites {
        let target = try #require(restored.favoriteTarget(favorite.id))
        #expect(target.page.address == favorite.launchAddress)
    }
    let gmail = try #require(restored.favorites.first)
    let gmailTarget = try #require(restored.favoriteTarget(gmail.id))
    restored.editTab(gmailTarget.tab.id) { $0.pages[0].address = "https://mail.google.com/mail/u/3/#inbox" }
    restored.customizeFavorite(gmail.id)
    #expect(restored.saveFavoriteCustomization(try #require(restored.favoriteCustomization), email: "person+work@example.com") == nil)
    #expect(restored.favoriteTarget(gmail.id)?.page.address == "https://mail.google.com/mail/u/3/#inbox")
    restored.customizeFavorite(gmail.id)
    let edit = try #require(restored.favoriteCustomization)
    #expect(edit.email == "person+work@example.com")
    #expect(restored.saveFavoriteCustomization(edit, email: "other@example.com") == nil)
    #expect(restored.favorites[0].id == gmail.id)
    #expect(restored.favorites[0].googleAccountEmail == "other@example.com")
    restored.newTab(address: "https://mail.google.com/mail/u/0/")
    restored.requestFavorite(restored.selectedTab.id)
    #expect(restored.saveFavoriteCustomization(try #require(restored.favoriteCustomization), email: "third@example.com") == nil)
    #expect(restored.favorites.count == 4)
    restored.customizeFavorite(gmail.id)
    #expect(restored.saveFavoriteCustomization(try #require(restored.favoriteCustomization), email: "third@example.com") != nil)
    #expect(restored.favorites[0].googleAccountEmail == "other@example.com")
    #expect(restored.saveFavoriteCustomization(try #require(restored.favoriteCustomization), email: "") == nil)
    #expect(restored.favorites[0].googleAccountEmail == nil)
    #expect(restored.favorites[0].address == GoogleFavoriteService.gmail.home)
    restored.newTab(address: "https://drive.google.com/drive/u/1/folders/abc")
    restored.requestFavorite(restored.selectedTab.id)
    let unchanged = restored.selectedTab.pages[0].address
    #expect(restored.saveFavoriteCustomization(try #require(restored.favoriteCustomization), email: "") == nil)
    #expect(restored.favorites.last?.address == unchanged)
    restored.newTab(address: "https://example.com/")
    restored.requestFavorite(restored.selectedTab.id)
    #expect(restored.favoriteCustomization == nil)
    #expect(restored.favorites.last?.address == "https://example.com/")
    restored.newTab(address: "https://mail.google.com/mail/u/1/")
    restored.requestFavorite(restored.selectedTab.id)
    let stale = try #require(restored.favoriteCustomization)
    restored.editTab { $0.pages[0].address = "https://example.org/" }
    #expect(restored.saveFavoriteCustomization(stale, email: "new@example.com") != nil)
}

// @lat: [[lat.md/tests/favorites-tests#Favorite location entry preserves the source]]
@Test @MainActor func favoriteLocationEntryPreservesSource() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendFavoriteLocation-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    let page = store.selectedTab.pages[0]
    let source = store.controller(for: page)
    source.address = "http://127.0.0.1:9/inbox"
    source.onNavigation?(source.address, "Inbox")
    store.focus(page.id)
    let favorite = try #require(store.addFavorite(store.selectedTab.id))
    let original = store.selectedTab
    let web = source.webView
    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 900, height: 600),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let popup = AddressPanelController(store: store, parentWindow: window)
    window.orderFront(nil)
    defer { popup.dismiss(restoreFocus: false); window.close() }
    popup.show(for: page.id)
    let panel = try #require(window.childWindows?.first { $0.title == "Open Location" })
    func fields(_ view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
    }
    let content = try #require(panel.contentView)
    let input = try #require(fields(content).first { $0.isEditable })
    input.stringValue = "browse://guide"
    #expect(input.sendAction(try #require(input.action), to: input.target))
    #expect(!panel.isVisible)
    #expect(store.selectedTab.id != original.id)
    #expect(store.selectedTab.pages[0].address == "browse://guide")
    #expect(store.selectedTab.pages[0].favoriteID == nil)
    #expect(store.favorites.count == 1)
    #expect(source.address == "http://127.0.0.1:9/inbox")
    #expect(store.existingController(for: page.id)?.webView === web)
    #expect(store.favoriteTarget(favorite)?.tab.id == original.id)
    store.openFavorite(favorite)
    #expect(!store.openLocation("file:///tmp/page.html", for: page.id))
    #expect(store.selectedTab.id == original.id)
    #expect(store.openLocation("http://127.0.0.1:9/same-site", for: page.id))
    #expect(store.selectedTab.id == original.id)
    source.webView.stopLoading()
    #expect(store.openLocation("search phrase", for: page.id))
    #expect(store.selectedTab.id != original.id)
    #expect(store.selectedTab.pages[0].address.contains("google.com/search") == true)
    #expect(!store.openLocation("https://example.org/", for: page.id)) // stale popup target
}

// @lat: [[lat.md/tests/favorites-tests#Google favorite popup presentation]]
@Test @MainActor func googleFavoritePopupPresentation() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendGooglePopup-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    store.newTab()
    let page = store.selectedTab.pages[0]
    let controller = store.controller(for: page)
    controller.address = "https://mail.google.com/mail/u/2/"
    controller.onNavigation?(controller.address, "Gmail")
    let context = BrowserWindowSession(id: UUID().uuidString, store: store)
    let window = context.window
    window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    window.orderFront(nil)
    defer { window.close() }
    store.requestFavorite(store.selectedTab.id)
    for _ in 0..<20 {
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        if window.attachedSheet != nil { break }
    }
    let sheet = try #require(window.attachedSheet)
    let content = try #require(sheet.contentView)
    func fields(_ view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
    }
    try await Task.sleep(for: .milliseconds(200))
    #expect(fields(content).contains { $0.isEditable })
    #expect(store.favorites.isEmpty)
    if let path = ProcessInfo.processInfo.environment["BEND_GOOGLE_POPUP_SNAPSHOT"],
       let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
    let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: 0, windowNumber: sheet.windowNumber, context: nil,
        characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
    #expect(sheet.performKeyEquivalent(with: escape))
    try await Task.sleep(for: .milliseconds(250))
    #expect(store.favoriteCustomization == nil)
    #expect(store.favorites.isEmpty)
}
