import AppKit
import SwiftUI

/// Native slider tracking and accessibility, with the compact macOS volume-track appearance.
struct MediaProgressSlider: NSViewRepresentable {
    @Binding var value: Double
    let duration: Double
    var seekable = true
    var onEditingChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> TrackSlider {
        let slider = TrackSlider()
        slider.sliderType = .linear
        slider.controlSize = .mini
        slider.isContinuous = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.onEditingChanged = { [weak coordinator = context.coordinator] editing in
            coordinator?.parent.onEditingChanged(editing)
        }
        return slider
    }

    func updateNSView(_ slider: TrackSlider, context: Context) {
        context.coordinator.parent = self
        slider.minValue = 0
        slider.maxValue = duration
        if !slider.tracking { slider.doubleValue = value }
        slider.isEnabled = seekable
        slider.needsDisplay = true
    }

    @MainActor final class Coordinator: NSObject {
        var parent: MediaProgressSlider
        init(_ parent: MediaProgressSlider) { self.parent = parent }

        @objc func changed(_ slider: TrackSlider) {
            // Keyboard and accessibility adjustments are complete, single-step seeks.
            if !slider.tracking { parent.onEditingChanged(true) }
            parent.value = slider.doubleValue
            if !slider.tracking { parent.onEditingChanged(false) }
        }
    }

    final class TrackSlider: NSSlider {
        override class var cellClass: AnyClass? {
            get { TrackCell.self }
            set {}
        }
        var tracking = false
        var onEditingChanged: ((Bool) -> Void)?

        // Modern AppKit can install an internal SwiftUI input view. Keep the
        // gesture on this control so one drag always produces one final seek.
        override func hitTest(_ point: NSPoint) -> NSView? {
            super.hitTest(point) == nil ? nil : self
        }

        override func mouseDown(with event: NSEvent) {
            guard isEnabled else { return }
            _ = window?.makeFirstResponder(self)
            tracking = true
            onEditingChanged?(true)
            _ = cell?.trackMouse(with: event, in: bounds, of: self, untilMouseUp: true)
            tracking = false
            onEditingChanged?(false)
        }

        override func keyDown(with event: NSEvent) { interpretKeyEvents([event]) }
        override func moveRight(_ sender: Any?) { adjust(by: 5) }
        override func moveLeft(_ sender: Any?) { adjust(by: -5) }
        override func moveUp(_ sender: Any?) { adjust(by: 5) }
        override func moveDown(_ sender: Any?) { adjust(by: -5) }

        override func accessibilityPerformIncrement() -> Bool {
            guard isEnabled else { return false }
            adjust(by: 5)
            return true
        }

        override func accessibilityPerformDecrement() -> Bool {
            guard isEnabled else { return false }
            adjust(by: -5)
            return true
        }

        private func adjust(by seconds: Double) {
            guard isEnabled else { return }
            doubleValue = min(maxValue, max(minValue, doubleValue + seconds))
            sendAction(action, to: target)
            needsDisplay = true
        }
    }

    private final class TrackCell: NSSliderCell {
        override func drawBar(inside rect: NSRect, flipped: Bool) {
            let track = NSRect(x: rect.minX, y: rect.midY - 2, width: rect.width, height: 4)
            NSColor.labelColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
            let fraction = maxValue > minValue ? min(1, max(0, (doubleValue - minValue) / (maxValue - minValue))) : 0
            let fill = NSRect(x: track.minX, y: track.minY, width: track.width * fraction, height: track.height)
            NSColor.labelColor.withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: fill, xRadius: 2, yRadius: 2).fill()
        }

        override func drawKnob(_ knobRect: NSRect) {}
    }
}
