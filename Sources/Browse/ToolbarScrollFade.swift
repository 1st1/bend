import SwiftUI

// Shared opacity mask: scrolling content fades out behind fixed toolbar controls.
struct ToolbarScrollFade: View {
    var height: CGFloat
    var clearHeight: CGFloat = 0
    var bottomFadeHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: clearHeight)
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .clear, location: 0.35),
                .init(color: .black, location: 1)
            ], startPoint: .top, endPoint: .bottom)
                .frame(height: max(0, height - clearHeight) + 16)
            Color.black
            if bottomFadeHeight > 0 {
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: bottomFadeHeight)
            }
        }
    }
}
