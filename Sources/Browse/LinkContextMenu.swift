import AppKit
import BrowseCore

extension PageController {
    private struct LinkMenuAction {
        let url: URL
        let mainFrame: Bool
        let destination: LinkOpenDestination
    }

    // @lat: [[lat.md/architecture/link-navigation#Link context menus]]
    override func contextMenu(_ menu: NSMenu, forLinkURL url: URL, fromMainFrame mainFrame: Bool) -> NSMenu {
        guard onOpenLink != nil else { return menu }
        // WebKit's OpenLinkInNewWindow tag is 1. Replace it with our explicit
        // destinations; keep Copy Link, Download, extension items, and Inspect.
        for item in menu.items where item.tag == 1 { menu.removeItem(item) }
        let choices: [(String, LinkOpenDestination)] = [
            ("Open Link in New Tab", .newTab),
            ("Open Link in New Pane", .newPane),
            ("Open Link in New Window", .newWindow)
        ]
        for (index, choice) in choices.enumerated() {
            let item = NSMenuItem(title: choice.0, action: #selector(openLinkFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = LinkMenuAction(url: url, mainFrame: mainFrame, destination: choice.1)
            menu.insertItem(item, at: index)
        }
        if menu.items.count > choices.count && !menu.items[choices.count].isSeparatorItem {
            menu.insertItem(.separator(), at: choices.count)
        }
        return menu
    }

    @objc private func openLinkFromMenu(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? LinkMenuAction else { return }
        onOpenLink?(action.url.absoluteString, action.mainFrame, action.destination)
    }
}
