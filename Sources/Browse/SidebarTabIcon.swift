import AppKit
import SwiftUI
import BrowseCore

struct SidebarTabIcon: NSViewRepresentable {
    @ObservedObject var store: BrowserStore
    let tab: BrowserTab

    func makeNSView(context: Context) -> SidebarTabIconView {
        let view = SidebarTabIconView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.clipsToBounds = true
        view.setAccessibilityElement(false)
        return view
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SidebarTabIconView, context: Context) -> CGSize? {
        // A SwiftUI frame alone does not override NSImageView's raster-sized
        // fitting size. Give the native view the same fixed icon slot.
        CGSize(width: 16, height: 16)
    }

    func updateNSView(_ view: SidebarTabIconView, context: Context) {
        view.tabID = tab.id
        let page = tab.pages.first
        let controller = page.flatMap { store.existingController(for: $0.id) }
        if let image = controller?.favicon, controller?.isStartPage == false {
            view.image = image
            view.contentTintColor = nil
        } else {
            let address = controller?.address ?? page?.address ?? "browse://start"
            let symbol = address.hasPrefix("browse://")
                ? (address == "browse://history" ? "clock" : "square.grid.2x2")
                : (tab.pages.count > 1 ? "rectangle.split.2x1" : "globe")
            view.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            view.contentTintColor = .secondaryLabelColor
        }
    }
}

final class SidebarTabIconView: NSImageView {
    var tabID: UUID?
}
