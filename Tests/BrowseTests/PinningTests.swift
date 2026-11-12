import AppKit
import SwiftUI
import Testing
import BrowseCore
@testable import Browse

// @lat: [[lat.md/tests/pane-controls-tests#Pinned pane protection]]
@Test @MainActor func pinnedPaneProtection() throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendPins-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("session.json")
    let store = BrowserStore(sessionFile: file, persistentExtensions: false)
    let original = store.selectedTab
    let pinned = original.pages[0], ordinary = original.pages[1]
    let web = store.controller(for: pinned).webView
    store.setPanePinned(pinned.id, pinned: true)
    #expect(store.selectedTab.isPinned)
    #expect(!store.isPanePinned(ordinary.id))
    store.zoomedPane = pinned.id
    store.closePane(pinned.id)
    store.closePage(pinned.id)
    store.closeTab(original.id)
    #expect(store.selectedTab.pages.map(\.id) == original.pages.map(\.id))
    #expect(store.zoomedPane == pinned.id)
    #expect(store.existingController(for: pinned.id)?.webView === web)
    #expect(!store.canReopenClosed)
    var model = store.selectedTab
    model.closePane(pinned.id)
    #expect(model.pages.count == 2)
    store.save()
    let restored = BrowserStore(sessionFile: file, persistentExtensions: false)
    #expect(restored.selectedTab.isPinned && restored.isPanePinned(pinned.id))
    #expect(!restored.isPanePinned(ordinary.id))
    let legacy = Data("{\"id\":\"\(UUID())\",\"address\":\"browse://start\"}".utf8)
    #expect(try !JSONDecoder().decode(Page.self, from: legacy).isPinned)

    store.setTabPinned(original.id, pinned: true)
    #expect(store.selectedTab.pages.allSatisfy { $0.isPinned })
    store.setPanePinned(ordinary.id, pinned: false)
    #expect(store.selectedTab.isPinned)
    store.closePage(ordinary.id)
    #expect(store.selectedTab.pages.map(\.id) == [pinned.id])
    store.closePage(pinned.id)
    #expect(store.selectedTab.id == original.id)
    store.reopenClosed()
    #expect(store.selectedTab.pages.count == 2 && !store.isPanePinned(ordinary.id))
    #expect(!store.canReopenClosed)
    store.toggleTabPinned(original.id)
    #expect(store.selectedTab.pages.allSatisfy { !$0.isPinned })
    store.closeTab(original.id)
    #expect(store.selectedTab.id != original.id && store.canReopenClosed)
    // Reopening a closed tab must not delete a pinned automatic replacement.
    let replacement = store.selectedTab
    store.setPanePinned(replacement.focusedPane, pinned: true)
    store.reopenClosed()
    #expect(store.session.workspaces[0].tabs.contains { $0.id == replacement.id && $0.isPinned })

    store.newTab()
    let blank = store.selectedTab
    store.setTabPinned(blank.id, pinned: true)
    #expect(!store.cancelInitialAddressEntry(for: blank.focusedPane))
    #expect(store.selectedTab.id == blank.id)
    store.setTabPinned(blank.id, pinned: false)
    #expect(store.cancelInitialAddressEntry(for: blank.focusedPane))
    store.newTab(address: "browse://guide", closeIfDownload: true)
    let download = store.selectedTab
    let downloadController = store.controller(for: download.pages[0])
    store.setTabPinned(download.id, pinned: true)
    downloadController.onInitialDownload?()
    #expect(store.selectedTab.id == download.id)
    #expect(store.existingController(for: download.focusedPane) === downloadController)
    store.setTabPinned(download.id, pinned: false)
    downloadController.onInitialDownload?()
    #expect(!store.session.workspaces[0].tabs.contains { $0.id == download.id })
}

// @lat: [[lat.md/tests/pane-controls-tests#Pinned pane transfers]]
@Test @MainActor func pinnedPaneTransfers() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendPinTransfers-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    let original = source.selectedTab
    let moving = original.pages[0]
    source.setPanePinned(moving.id, pinned: true)
    let web = source.controller(for: moving).webView
    source.newTab(address: "browse://guide")
    let destination = source.selectedTab
    #expect(source.movePane(moving.id, beside: destination.focusedPane, edge: .right,
                            in: destination.id, from: original.id))
    #expect(source.selectedTab.isPinned && source.isPanePinned(moving.id))
    #expect(source.session.isValid)
    #expect(!source.session.workspaces[0].tabs.first { $0.id == original.id }!.isPinned)
    #expect(source.detachPane(moving.id, from: destination.id, into: source.session.workspaces[0].id))
    let detached = source.selectedTab.id
    #expect(source.selectedTab.pages.map(\.id) == [moving.id] && source.selectedTab.isPinned)
    #expect(source.joinTabs(detached, into: destination.id))
    #expect(source.selectedTab.isPinned && source.session.isValid)
    let other = BrowserStore(sessionFile: root.appendingPathComponent("other.json"), sharedStore: source)
    #expect(source.transfer(tab: destination.id, pane: moving.id, to: other,
                            at: .workspace(other.session.workspaces[0].id)))
    #expect(other.selectedTab.isPinned && other.isPanePinned(moving.id))
    #expect(other.existingController(for: moving.id)?.webView === web)
    #expect(source.session.isValid && other.session.isValid)
    #expect(!source.canReopenClosed && !other.canReopenClosed)
    other.closeTab(other.selectedTab.id)
    #expect(other.isPanePinned(moving.id))
    other.save()
    let restored = BrowserStore(sessionFile: root.appendingPathComponent("other.json"), persistentExtensions: false)
    #expect(restored.isPanePinned(moving.id))
    #expect(restored.selectedTab.pages.first { $0.id == moving.id }?.pinnedAddress == moving.address)
}

// @lat: [[lat.md/tests/pane-controls-tests#Pinned close commands]]
@Test @MainActor func pinnedCloseCommands() throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendPinCommands-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let owner = BrowserWindows(root: root, persistentExtensions: false)
    owner.restore(show: false)
    let first = try #require(owner.active)
    _ = owner.newWindow(show: false)
    first.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: first.window))
    let pinned = Page(isPinned: true)
    let tab = BrowserTab(pages: [pinned])
    first.store.session.workspaces = [Workspace(name: "Tabs", tabs: [tab])]
    first.store.session.selectedTab = tab.id
    let delegate = AppDelegate(browserWindows: owner)
    defer { owner.prepareToQuit(); for context in owner.windows { context.window.close() } }
    delegate.closeFocusedWindow(first.window)
    #expect(owner.windows.count == 2)
    #expect(first.store.selectedTab.id == tab.id && first.store.isPanePinned(pinned.id))
    #expect(!first.windowShouldClose(first.window))
    first.window.performClose(nil)
    #expect(owner.windows.count == 2)
    first.store.setPanePinned(pinned.id, pinned: false)
    #expect(first.windowShouldClose(first.window))
    delegate.closeFocusedWindow(first.window)
    #expect(owner.windows.count == 1)
}

// @lat: [[lat.md/tests/pane-controls-tests#Native pin controls]]
@Test @MainActor func nativePinControls() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendPinControls-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    let tab = store.selectedTab
    let first = tab.pages[0].id, second = tab.pages[1].id
    store.setPanePinned(first, pinned: true)
    store.focus(second)
    let context = BrowserWindowSession(id: UUID().uuidString, store: store)
    let window = context.window
    window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    window.makeKeyAndOrderFront(nil)
    defer { OptionKeyState.shared.refresh(); window.close() }
    let content = try #require(window.contentView)
    func settle() async throws {
        for _ in 0..<4 { content.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(50)) }
    }
    func descendants<T: NSView>(_ type: T.Type, _ view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(type, $0) }
    }
    func click(_ point: NSPoint, option: Bool = false) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point,
                modifierFlags: option ? .option : [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0))
            // Direct dispatch bypasses AppKit's local event monitors. Supply
            // the same modifier update that the production monitor performs.
            OptionKeyState.shared.update(event.modifierFlags)
            NSApp.sendEvent(event)
        }
    }
    func flags(_ option: Bool) throws {
        let event = try #require(NSEvent.keyEvent(with: .flagsChanged, location: .zero,
            modifierFlags: option ? .option : [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: 58))
        OptionKeyState.shared.update(event.modifierFlags)
        NSApp.sendEvent(event)
    }
    func paneButton(_ id: UUID) throws -> NSPoint {
        let pane = try #require(descendants(ClippedPaneHost.self, content).first { $0.pageID == id })
        return pane.convert(NSPoint(x: pane.bounds.maxX - 24, y: pane.bounds.maxY - 18), to: nil)
    }
    try await settle()
    try flags(true)
    #expect(OptionKeyState.shared.pressed)
    try await settle()
    try click(paneButton(second), option: true)
    try flags(false)
    try await settle()
    #expect(store.isPanePinned(second))
    #expect(store.selectedTab.pages.count == 2)
    let firstController = store.controller(for: tab.pages[0])
    firstController.navigate("browse://history")
    try await settle()
    #expect(store.pinnedReturnAddress(first) == "browse://start")
    // Return remains clickable even while this pinned pane is inactive.
    let pinPoint = try paneButton(first)
    try click(NSPoint(x: pinPoint.x - 24, y: pinPoint.y))
    try await settle()
    #expect(firstController.address == "browse://start")
    #expect(store.isPanePinned(first))
    store.focus(second)
    try await settle()
    // The first pane is inactive and unhovered, but its pin remains clickable.
    try click(paneButton(first))
    try await settle()
    #expect(!store.isPanePinned(first) && store.isPanePinned(second))
    #expect(store.selectedTab.focusedPane == second)
    // Option-click the sidebar row to unpin all, then pin all again.
    let row = try #require(descendants(TabDragSourceView.self, content).first { $0.tabID == tab.id })
    let rowCenter = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
    try click(rowCenter, option: true)
    try await settle()
    #expect(store.selectedTab.pages.allSatisfy { !$0.isPinned })
    try click(rowCenter, option: true)
    try await settle()
    #expect(store.selectedTab.pages.allSatisfy { $0.isPinned })
    store.newTab(address: "browse://guide")
    try await settle()
    let target = try #require(descendants(PaneSidebarTargetView.self, content).first {
        if case .tab(tab.id) = $0.destination { return true }; return false
    })
    try click(target.convert(NSPoint(x: target.bounds.maxX - 19, y: target.bounds.midY), to: nil))
    try await settle()
    #expect(store.session.workspaces[0].tabs.first { $0.id == tab.id }?.isPinned == false)
}

// @lat: [[lat.md/tests/pane-controls-tests#Pinned URL return]]
@Test @MainActor func pinnedURLReturn() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendPinURL-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("session.json")
    let store = BrowserStore(sessionFile: file, persistentExtensions: false)
    let page = store.selectedTab.pages[0]
    let controller = store.controller(for: page)
    controller.navigate("browse://history")
    store.setPanePinned(page.id, pinned: true)
    #expect(store.selectedTab.pages[0].pinnedAddress == "browse://history")
    #expect(store.pinnedReturnAddress(page.id) == nil)
    controller.navigate("browse://guide")
    #expect(store.pinnedReturnAddress(page.id) == "browse://history")
    store.setTabPinned(store.selectedTab.id, pinned: true)
    #expect(store.selectedTab.pages[0].pinnedAddress == "browse://history")
    store.save()
    let restored = BrowserStore(sessionFile: file, persistentExtensions: false)
    #expect(restored.pinnedReturnAddress(page.id) == "browse://history")
    restored.returnToPinnedURL(page.id)
    #expect(restored.existingController(for: page.id)?.address == "browse://history")
    #expect(restored.pinnedReturnAddress(page.id) == nil)
    store.returnToPinnedURL(page.id)
    #expect(store.existingController(for: page.id) === controller)
    #expect(controller.address == "browse://history")
    store.setPanePinned(page.id, pinned: false)
    #expect(store.selectedTab.pages[0].pinnedAddress == nil)
    controller.navigate("browse://guide")
    store.setPanePinned(page.id, pinned: true)
    #expect(store.selectedTab.pages[0].pinnedAddress == "browse://guide")
    let legacy = Data("{\"id\":\"\(UUID())\",\"address\":\"browse://history\",\"isPinned\":true}".utf8)
    #expect(try JSONDecoder().decode(Page.self, from: legacy).pinnedAddress == "browse://history")
}
