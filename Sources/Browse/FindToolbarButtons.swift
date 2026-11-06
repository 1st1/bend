import SwiftUI

struct FindToolbarButtons: View {
    var canNavigate: Bool
    let previous: () -> Void
    let next: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: previous) { Image(systemName: "chevron.up") }
                .disabled(!canNavigate)
                .help("Previous match · ⇧⌘G").accessibilityLabel("Previous match")
            Button(action: next) { Image(systemName: "chevron.down") }
                .disabled(!canNavigate)
                .help("Next match · ⌘G").accessibilityLabel("Next match")
            Button(action: close) { Image(systemName: "xmark") }
                .help("Close find bar · Escape").accessibilityLabel("Close find bar")
        }
        .buttonStyle(ChromeButtonStyle())
    }
}
