import AppKit
import SwiftUI

private typealias ButtonState<Value> = SwiftUI.State<Value>

// @lat: [[architecture#Toolbar button styling]]
struct ChromeButtonStyle: ButtonStyle {
    static let highlightBackground = Color.white.opacity(0.06)
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        ChromeButton(configuration: configuration, prominent: prominent)
    }

    private struct ChromeButton: View {
        let configuration: Configuration
        let prominent: Bool
        @ButtonState<Bool> private var hovered = false
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        private var highlighted: Bool { enabled && (hovered || configuration.isPressed) }
        private var iconColor: Color {
            if prominent {
                return highlighted ? Color(red: 0.87, green: 0.89, blue: 0.90) : Color(red: 0.67, green: 0.69, blue: 0.70)
            }
            return highlighted ? Color(red: 0.54, green: 0.56, blue: 0.59) : Color(red: 0.41, green: 0.43, blue: 0.46)
        }

        var body: some View {
            configuration.label
                .font(.system(size: prominent ? 14 : 12, weight: .regular))
                .imageScale(.medium)
                .foregroundStyle(iconColor.opacity(enabled ? 1 : 0.4))
                .frame(width: prominent ? 28 : 24, height: prominent ? 28 : 24)
                .background {
                    Circle()
                        .fill(ChromeButtonStyle.highlightBackground.opacity(highlighted ? 1 : 0))
                        .frame(width: prominent ? 28 : 22, height: prominent ? 28 : 22)
                }
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
                // Native menu tracking can swallow the mouse-exit event.
                // Clear the cached hover on both sides of that tracking loop.
                .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
                    hovered = false
                }
                .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
                    hovered = false
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: highlighted)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
        }
    }
}
