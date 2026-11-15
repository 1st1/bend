import SwiftUI

// Shared opacity mask: scrolling content fades out behind fixed toolbar controls.
struct ToolbarScrollFade: View {
    static let contentInset: CGFloat = 32
    var height: CGFloat
    var contentPadding: CGFloat = Self.contentInset
    var clearHeight: CGFloat = 0
    var bottomFadeHeight: CGFloat = 0

    var body: some View {
        // Content is fully hidden above the toolbar midpoint. Begin fading
        // farther below the toolbar so rows disappear before reaching controls.
        let hiddenHeight = clearHeight + max(0, height - clearHeight) / 2
        return VStack(spacing: 0) {
            Color.clear.frame(height: hiddenHeight)
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: max(0, height - hiddenHeight) + contentPadding)
            Color.black
            if bottomFadeHeight > 0 {
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: bottomFadeHeight)
            }
        }
    }
}
