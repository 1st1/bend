import AppKit
import SwiftUI
import Testing
import BrowseCore
@testable import Browse

// @lat: [[tests#Divider pointer tracking]]
@Test(.serialized, arguments: [SplitAxis.horizontal, .vertical]) @MainActor
func dividerPointerTracking(axis: SplitAxis) async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseResize-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    let a = Page(address: "browse://start"), b = Page(address: "browse://start"), splitID = UUID()
    var tab = BrowserTab(pages: [a, b])
    tab.layout = .split(id: splitID, axis: axis, fraction: 0.5, first: .pane(a.id), second: .pane(b.id))
    store.session.workspaces = [Workspace(name: "Test", tabs: [tab])]
    store.session.selectedTab = tab.id
    let host = MountedTabHost(frame: NSRect(x: 0, y: 0, width: 1100, height: 900))
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    window.orderFront(nil)
    defer { window.orderOut(nil); window.contentView = nil }
    func settle() async throws {
        host.update(store: store, environment: EnvironmentValues())
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
    }
    func divider() throws -> DividerPlacement {
        try #require(PaneGeometry(layout: store.selectedTab.layout, viewport: host.bounds.size).dividers.first)
    }
    try await settle()
    let initial = try divider()
    let down = host.convert(NSPoint(x: initial.frame.midX, y: host.bounds.height - initial.frame.midY), to: nil)
    try sendPaneMouse(.leftMouseDown, at: down, to: window)
    // Repeating the same pointer coordinate after layout catches feedback from
    // the divider's own movement. Reversals must track without bouncing too.
    for delta in [20.0, 40, 40, 60, 80, 80, 40, 0, -40, -40] {
        let point = NSPoint(x: down.x + (axis == .horizontal ? delta : 0),
                           y: down.y - (axis == .vertical ? delta : 0))
        try sendPaneMouse(.leftMouseDragged, at: point, to: window)
        try await settle()
        let actual = try divider().firstLength
        print("DIVIDER_TRACKING", axis, delta, actual - initial.firstLength)
        #expect(abs(actual - initial.firstLength - delta) < 2)
    }
    let up = NSPoint(x: down.x - (axis == .horizontal ? 40 : 0), y: down.y + (axis == .vertical ? 40 : 0))
    try sendPaneMouse(.leftMouseUp, at: up, to: window)
    try await settle()
    #expect(abs(try divider().firstLength - initial.firstLength + 40) < 2)
}
