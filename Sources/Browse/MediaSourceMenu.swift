import AppKit
import SwiftUI

@MainActor
final class MediaSourceMenu: NSObject {
    weak var anchor: NSView?
    private var onSelect: ((String) -> Void)?

    func makeMenu(sources: [SidebarMediaSource], selectedID: String?,
                  favicon: (UUID) -> NSImage?, onSelect: @escaping (String) -> Void) -> NSMenu {
        self.onSelect = onSelect
        let menu = NSMenu()
        menu.autoenablesItems = false
        for source in sources {
            let item = NSMenuItem(title: "\(source.state.title) — \(source.state.site)",
                                  action: #selector(selectSource(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = source.id
            item.state = source.id == selectedID ? .on : .off
            let original = favicon(source.paneID) ?? NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)
            item.image = original?.copy() as? NSImage
            item.image?.size = NSSize(width: 16, height: 16)
            // This public macOS 27 property is optional at runtime. KVC keeps
            // the macOS 26 SDK buildable; 1 is NSMenuItemImageVisibilityVisible.
            if item.responds(to: NSSelectorFromString("setPreferredImageVisibility:")) {
                item.setValue(1, forKey: "preferredImageVisibility")
            }
            menu.addItem(item)
        }
        return menu
    }

    func show(sources: [SidebarMediaSource], selectedID: String?, favicon: (UUID) -> NSImage?,
              onSelect: @escaping (String) -> Void) {
        guard let anchor, anchor.window != nil else { return }
        let menu = makeMenu(sources: sources, selectedID: selectedID, favicon: favicon, onSelect: onSelect)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.maxY + 2), in: anchor)
        self.onSelect = nil
    }

    @objc private func selectSource(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        onSelect?(id)
    }
}

struct MediaSourceMenuAnchor: NSViewRepresentable {
    let menu: MediaSourceMenu
    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        menu.anchor = view
        return view
    }
    func updateNSView(_ view: AnchorView, context: Context) { menu.anchor = view }

    final class AnchorView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
