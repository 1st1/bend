import AppKit
import SwiftUI
import Testing
import BrowseCore
@testable import Browse

// @lat: [[lat.md/tests/pane-materials-tests#Pane shadow boundaries]]
@Test @MainActor func paneShadowBoundaries() throws {
    _ = NSApplication.shared
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 240))
    let window = NSWindow(contentRect: root.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = root
    window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
    let shadows = PaneShadowView(frame: root.bounds)
    root.addSubview(shadows)
    let canvas = MountedTabHost(frame: NSRect(x: 40, y: 40, width: 200, height: 160))
    root.addSubview(canvas)
    let pane = ClippedPaneHost(content: AnyView(Color.clear))
    pane.frame = canvas.bounds
    canvas.addSubview(pane)
    window.orderFront(nil)
    defer { window.close() }
    root.layoutSubtreeIfNeeded()
    func color(x: Int, y: Int) throws -> NSColor {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 300, pixelsHigh: 240,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        shadows.draw(shadows.bounds)
        return try #require(bitmap.colorAt(x: x, y: y))
    }
    func alpha(x: Int, y: Int) throws -> CGFloat { try color(x: x, y: y).alphaComponent }
    // This point is beyond the clipped canvas, but within its pane's shadow.
    #expect(try alpha(x: 37, y: 120) > 0.01)
    #expect(try alpha(x: 100, y: 120) == 0)
    #expect(try alpha(x: 10, y: 120) == 0)
    #expect(shadows.hitTest(NSPoint(x: 37, y: 120)) == nil)
    // The neutral edge fades in below the glass header and never enters the page.
    let edge = try color(x: 39, y: 120)
    let headerEdge = try color(x: 39, y: 184)
    #expect(edge.redComponent * edge.alphaComponent > headerEdge.redComponent * headerEdge.alphaComponent)
    #expect(edge.redComponent > 0 && abs(edge.redComponent - edge.greenComponent) < 0.01)
    #expect(try color(x: 120, y: 200).redComponent == 0)
    pane.isHidden = true
    #expect(try alpha(x: 37, y: 120) == 0)
    pane.isHidden = false
    pane.setFrameOrigin(NSPoint(x: 40, y: 0))
    #expect(try alpha(x: 37, y: 120) == 0)
    #expect(try alpha(x: 77, y: 120) > 0.01)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BendShadowGlow-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = BrowserStore(sessionFile: directory.appendingPathComponent("session.json"), persistentExtensions: false)
    let tab = BrowserTab(pages: [Page(), Page()])
    store.session.workspaces = [Workspace(name: "Test", tabs: [tab])]
    store.session.selectedTab = tab.id
    pane.frame = NSRect(x: 0, y: 0, width: 100, height: 160)
    pane.store = store; pane.tabID = tab.id; pane.pageID = tab.pages[0].id
    let neighbor = ClippedPaneHost(content: AnyView(Color.clear))
    neighbor.frame = NSRect(x: 120, y: 0, width: 80, height: 160)
    neighbor.store = store; neighbor.tabID = tab.id; neighbor.pageID = tab.pages[1].id
    canvas.addSubview(neighbor)
    store.paneHighlight.style = .glow
    store.paneHighlight.glowColor = .init(red: 1, green: 0, blue: 0)
    store.paneHighlight.glowIntensity = 0.5
    store.paneHighlight.glowSpread = 15
    neighbor.isHidden = true
    let topGlow = try alpha(x: 90, y: 37)
    let bottomGlow = try alpha(x: 90, y: 202)
    #expect(topGlow > 0.01 && bottomGlow > 0.01)
    #expect(abs(topGlow - bottomGlow) < 0.01)
    #expect(abs(try alpha(x: 37, y: 120) - alpha(x: 142, y: 120)) < 0.01)
    neighbor.isHidden = false
    let active = try color(x: 37, y: 120)
    #expect(active.redComponent > 0.9 && active.greenComponent < 0.1 && active.alphaComponent > 0.01)
    #expect(try color(x: 243, y: 120).redComponent == 0)
    #expect(try alpha(x: 41, y: 120) == 0)
    #expect(try alpha(x: 165, y: 120) == 0)
    store.focus(tab.pages[1].id)
    #expect(try color(x: 37, y: 120).redComponent == 0)
    #expect(try color(x: 243, y: 120).redComponent > 0.9)
    store.paneHighlight.glowSpread = 24
    let wide = try alpha(x: 250, y: 120)
    store.paneHighlight.glowSpread = 4
    #expect(try alpha(x: 250, y: 120) < wide)
    store.paneHighlight.glowIntensity = 0
    #expect(try alpha(x: 243, y: 120) == 0)
    store.paneHighlight.style = .outline
    #expect(try alpha(x: 243, y: 120) > 0.01)
    store.paneHighlight.outlineColor = .init(red: 0, green: 1, blue: 0)
    store.paneHighlight.outlineGap = 1
    store.paneHighlight.outlineWidth = 1
    // The ring is beyond the canvas edge, with an empty gap next to the pane.
    let gapEdge = try color(x: 240, y: 120)
    #expect(abs(gapEdge.greenComponent - gapEdge.redComponent) < 0.01)
    #expect(try color(x: 241, y: 120).greenComponent > 0.9)
    #expect(try color(x: 243, y: 120).greenComponent == 0)
    store.paneHighlight.outlineWidth = 2
    #expect(try color(x: 242, y: 120).greenComponent > 0.9)
    store.paneHighlight.outlineGap = 2.5
    let widerGap = try color(x: 241, y: 120)
    #expect(abs(widerGap.greenComponent - widerGap.redComponent) < 0.01)
    #expect(try color(x: 243, y: 120).greenComponent > 0.9)
    store.focus(tab.pages[0].id)
    #expect(try color(x: 243, y: 120).greenComponent == 0)
    #expect(try color(x: 143, y: 120).greenComponent > 0.9)
    neighbor.setFrameOrigin(NSPoint(x: 102, y: 0))
    #expect(try alpha(x: 143, y: 120) == 0)
    #expect(try alpha(x: 100, y: 120) == 0)
    pane.isHidden = true
    #expect(try color(x: 36, y: 120).greenComponent == 0)
}
