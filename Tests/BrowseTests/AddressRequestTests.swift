import Foundation
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
