#!/usr/bin/env swift
import AppKit

// Finder uses a multi-resolution TIFF so the installer remains sharp on Retina displays.
guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: render-dmg-background.swift OUTPUT.tiff")
}
let size = NSSize(width: 640, height: 400)
let image = NSImage(size: size)
for scale in [1, 2] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640 * scale, pixelsHigh: 400 * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)!
    let transform = NSAffineTransform()
    transform.scale(by: CGFloat(scale)); transform.concat()
    let background = NSBezierPath(rect: NSRect(origin: .zero, size: size))
    NSGradient(starting: NSColor(calibratedWhite: 0.97, alpha: 1),
               ending: NSColor(calibratedRed: 0.89, green: 0.92, blue: 0.91, alpha: 1))!
        .draw(in: background, angle: -90)

    func text(_ value: String, y: CGFloat, font: NSFont, color: NSColor) {
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        (value as NSString).draw(in: NSRect(x: 30, y: y, width: 580, height: 45), withAttributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph
        ])
    }
    text("Bend", y: 316, font: .systemFont(ofSize: 32, weight: .semibold),
         color: NSColor(calibratedWhite: 0.15, alpha: 1))
    text("Drag Bend to Applications to install.", y: 279, font: .systemFont(ofSize: 15),
         color: NSColor(calibratedWhite: 0.4, alpha: 1))
    let arrow = NSBezierPath()
    arrow.lineWidth = 2.5; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: 294, y: 200)); arrow.line(to: NSPoint(x: 346, y: 200))
    arrow.move(to: NSPoint(x: 334, y: 212)); arrow.line(to: NSPoint(x: 346, y: 200))
    arrow.line(to: NSPoint(x: 334, y: 188))
    NSColor(calibratedWhite: 0.5, alpha: 0.8).setStroke(); arrow.stroke()
    text("Once installed, eject this disk image.", y: 25, font: .systemFont(ofSize: 12),
         color: NSColor(calibratedWhite: 0.46, alpha: 1))
    NSGraphicsContext.restoreGraphicsState()
    bitmap.size = size
    image.addRepresentation(bitmap)
}
try NSBitmapImageRep.representationOfImageReps(in: image.representations, using: .tiff, properties: [:])!
    .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
