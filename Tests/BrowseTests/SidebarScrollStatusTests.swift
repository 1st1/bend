import AppKit
import Testing
@testable import Browse

// @lat: [[tests#Sidebar overflow counts]]
@Test func sidebarOverflowCounts() {
    // Five rows occupy 6...40, 47...81, 88...122, 129...163, 170...204.
    func status(_ top: CGFloat, _ bottom: CGFloat, count: Int = 5, inset: CGFloat = 6) -> SidebarScrollStatus {
        SidebarScrollStatus(visibleRect: CGRect(x: 0, y: top, width: 240, height: bottom - top),
                            tabCount: count, topInset: inset)
    }
    #expect(status(0, 122).above == 0)
    #expect(status(0, 122).below == 2)
    #expect(status(0, 122).topFadeHeight == 0)
    #expect(status(81, 163).above == 2)
    #expect(status(81, 163).below == 1)
    #expect(status(81, 163).topFadeHeight == 24)
    // Even a half-point of visible row keeps it out of the hidden count.
    #expect(status(80.5, 170.5).above == 1)
    #expect(status(80.5, 170.5).below == 0)
    #expect(status(81, 170).below == 1)
    #expect(status(8, 130).topFadeHeight == 8)
    #expect(status(81, 163, count: 7).below == 3)
    #expect(status(81, 163, count: 3).below == 0)
    #expect(status(81, 250).below == 0)
    #expect(status(81, 163, inset: 16).above == 1)
    #expect(status(81, 163, inset: 16).below == 1)
    #expect(status(-20, 250).above == 0)
    #expect(status(-20, 250).below == 0)
    #expect(status(250, 350).above == 5)
    #expect(status(0, 0) == SidebarScrollStatus())
    #expect(status(0, 100, count: 0) == SidebarScrollStatus())
}
