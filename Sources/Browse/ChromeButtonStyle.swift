import AppKit
import SwiftUI

private typealias ButtonState<Value> = SwiftUI.State<Value>

// @lat: [[architecture#Toolbar button styling]]
struct ChromeButtonStyle: ButtonStyle {
    static let highlightBackground = Color.primary.opacity(0.06)
    var prominent = false
    var pill = false

    func makeBody(configuration: Configuration) -> some View {
        ChromeButton(configuration: configuration, prominent: prominent, pill: pill)
    }

    private struct ChromeButton: View {
        let configuration: Configuration
        let prominent: Bool
        let pill: Bool
        @ButtonState<Bool> private var hovered = false
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.colorSchemeContrast) private var contrast

        private var highlighted: Bool { enabled && (hovered || configuration.isPressed) }
        // Hierarchical styles retain the system's material/vibrancy treatment.
        // Fixed RGB colors here made enabled controls resemble disabled ones.
        private var iconStyle: HierarchicalShapeStyle {
            if !enabled { return .tertiary }
            return highlighted || contrast == .increased ? .primary : .secondary
        }

        var body: some View {
            configuration.label
                .font(.system(size: prominent ? 14 : 12, weight: .regular))
                .imageScale(.medium)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(iconStyle)
                .padding(.horizontal, pill ? 6 : 0)
                .frame(width: pill ? nil : (prominent ? 28 : 24), height: prominent ? 28 : 24)
                .background {
                    Capsule()
                        .fill(ChromeButtonStyle.highlightBackground.opacity(highlighted ? 1 : 0))
                        .frame(width: pill ? nil : (prominent ? 28 : 22), height: prominent ? 28 : 22)
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
