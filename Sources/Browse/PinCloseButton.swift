import AppKit
import Combine
import SwiftUI

// One local monitor keeps the preview current even when Option changes while
// the pointer is stationary. Mouse events capture the modifiers before SwiftUI
// dispatches a button action, which may occur after NSApp.currentEvent changes.
@MainActor
final class OptionKeyState: ObservableObject {
    static let shared = OptionKeyState()
    @Published private(set) var pressed = NSEvent.modifierFlags.contains(.option)
    private var monitor: Any?
    private var observations: Set<AnyCancellable> = []

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .leftMouseDown, .leftMouseUp]) { [weak self] event in
            self?.update(event.modifierFlags)
            return event
        }
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refresh() }.store(in: &observations)
        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in self?.pressed = false }.store(in: &observations)
    }

    func update(_ flags: NSEvent.ModifierFlags) {
        let next = flags.contains(.option)
        if pressed != next { pressed = next }
    }
    func refresh() { update(NSEvent.modifierFlags) }
    static var optionAtClick: Bool { shared.pressed }
}

struct PinCloseButton: View {
    let pinned: Bool
    var tab = false
    let setPinned: (Bool) -> Void
    let close: () -> Void
    @ObservedObject private var option = OptionKeyState.shared

    private var label: String {
        if pinned { return tab ? "Unpin tab" : "Unpin pane" }
        if option.pressed { return tab ? "Pin tab" : "Pin pane" }
        return tab ? "Close tab" : "Close pane"
    }

    private var button: some View {
        Button {
            if pinned { setPinned(false) }
            else if OptionKeyState.optionAtClick { setPinned(true) }
            else { close() }
        } label: {
            Image(systemName: pinned ? "pin.fill" : (option.pressed ? "pin" : "xmark"))
                .frame(width: tab ? 16 : nil, height: tab ? 22 : nil)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
        .help(pinned || option.pressed ? label : "\(label) · \(tab ? "⌘⇧W" : "⌘W") · Option-click to pin")
        .onHover { if $0 { option.refresh() } }
    }

    var body: some View {
        if tab {
            button.font(.system(size: 9)).buttonStyle(.plain).foregroundStyle(Chrome.muted)
        } else {
            button.buttonStyle(ChromeButtonStyle())
        }
    }
}
