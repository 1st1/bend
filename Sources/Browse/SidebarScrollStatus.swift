import SwiftUI

struct SidebarScrollStatus: Equatable {
    var topFadeHeight: CGFloat = 0
    var above = 0
    var below = 0

    init() {}

    // @lat: [[architecture#Sidebar overflow indicators]]
    init(visibleRect: CGRect, tabCount: Int, topInset: CGFloat) {
        guard visibleRect.height > 0, tabCount > 0 else { return }
        topFadeHeight = min(Chrome.sidebarScrollFadeHeight, max(0, visibleRect.minY))
        let stride = Chrome.sidebarTabHeight + Chrome.sidebarTabSpacing
        // Count only fully hidden rows; a partially visible tab remains in view.
        above = min(tabCount, max(0, Int(floor((visibleRect.minY - topInset - Chrome.sidebarTabHeight) / stride)) + 1))
        below = min(tabCount, max(0, tabCount - Int(ceil((visibleRect.maxY - topInset) / stride))))
    }
}

struct SidebarOverflowPill: View {
    let count: Int
    let above: Bool

    var body: some View {
        Text("\(count) \(count == 1 ? "tab" : "tabs")")
            .font(.system(size: 9, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background { Capsule().fill(.regularMaterial).opacity(0.8) }
            .fixedSize()
            .accessibilityLabel("\(count) \(count == 1 ? "tab" : "tabs") \(above ? "above" : "below")")
            .allowsHitTesting(false)
    }
}
