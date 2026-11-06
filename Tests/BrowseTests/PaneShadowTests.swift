import AppKit
import SwiftUI
import Testing
@testable import Browse

// @lat: [[tests#Pane shadow boundaries]]
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
    func alpha(x: Int, y: Int) throws -> CGFloat {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 300, pixelsHigh: 240,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        shadows.draw(shadows.bounds)
        return try #require(bitmap.colorAt(x: x, y: y)).alphaComponent
    }
    // This point is beyond the clipped canvas, but within its pane's shadow.
    #expect(try alpha(x: 37, y: 120) > 0.01)
    #expect(try alpha(x: 100, y: 120) == 0)
    #expect(try alpha(x: 10, y: 120) == 0)
    #expect(shadows.hitTest(NSPoint(x: 37, y: 120)) == nil)
    pane.isHidden = true
    #expect(try alpha(x: 37, y: 120) == 0)
    pane.isHidden = false
    pane.setFrameOrigin(NSPoint(x: 40, y: 0))
    #expect(try alpha(x: 37, y: 120) == 0)
    #expect(try alpha(x: 77, y: 120) > 0.01)
}
