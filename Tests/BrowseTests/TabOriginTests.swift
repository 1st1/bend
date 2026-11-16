import AppKit
import BrowseCore
import Foundation
import Testing
@testable import Browse

// @lat: [[lat.md/tests/link-navigation-tests#Return to origin tab]]
@Test @MainActor func closingLinkTabReturnsToOrigin() throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    defer { store.stopWindow(); try? FileManager.default.removeItem(at: root) }
    let origin = store.selectedTab
    let controller = store.controller(for: origin.pages[0])
    store.newTab(address: "bend://history")
    let unrelated = store.selectedTab.id
    store.select(origin.id)
    // Context-menu iframe links have no WebKit opener, but retain their origin tab.
    controller.onOpenLink?("bend://history", false, .newTab)
    let child = try #require(store.session.workspaces.flatMap(\.tabs).first { $0.originTabID == origin.id })
    #expect(store.selectedTab.id == origin.id)
    store.select(child.id)
    store.controller(for: child.pages[0]).onNewTab?("bend://history")
    #expect(store.selectedTab.id == child.id)
    let grandchild = try #require(store.session.workspaces.flatMap(\.tabs).first { $0.originTabID == child.id }).id
    store.select(grandchild)
    store.closeTab(grandchild)
    #expect(store.selectedTab.id == child.id)
    // Persist origin metadata along with the session.
    let restored = try JSONDecoder().decode(BrowserSession.self, from: JSONEncoder().encode(store.session))
    #expect(restored.workspaces.flatMap(\.tabs).first { $0.id == child.id }?.originTabID == origin.id)
    store.closeTab(child.id)
    #expect(store.selectedTab.id == origin.id)
    controller.onNewLink?("bend://history", false, false)
    let second = try #require(store.session.workspaces.flatMap(\.tabs).first { $0.originTabID == origin.id }).id
    #expect(store.selectedTab.id == second)
    store.select(unrelated)
    store.closeTab(second)
    #expect(store.selectedTab.id == unrelated)
    store.select(origin.id)
    controller.onNewTab?("bend://history")
    #expect(store.selectedTab.id == origin.id)
    let orphan = try #require(store.session.workspaces.flatMap(\.tabs).first { $0.originTabID == origin.id }).id
    store.select(orphan)
    store.closeTab(origin.id)
    #expect(store.selectedTab.id == orphan)
    store.closeTab(orphan)
    #expect(store.selectedTab.id == unrelated)
    #expect(store.session.isValid)
}
