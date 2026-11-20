import AppKit

enum ShortcutGroup: String, CaseIterable {
    case tabs = "Tabs"
    case panes = "Panes"
    case ai = "AI"
    case generalUI = "General UI"
}

/// A command's availability is checked again immediately before execution.
@MainActor
struct PopupCommand {
    let id: String
    var group: ShortcutGroup = .generalUI
    let title: String
    var shortcutTitle: String? = nil
    let detail: String
    let icon: String
    var isEnabled: Bool = true
    var menuAction: Selector? = nil
    var menuTag: Int = 0
    let perform: () -> Void

    /// Resolve against the live menu so bindings are never copied into descriptions.
    var shortcut: String? {
        guard let menuAction else {
            guard let item = MenuShortcut.items(in: NSApp.mainMenu).first(where: {
                $0.action == #selector(AppDelegate.runPaletteShortcut(_:)) && $0.representedObject as? String == id
            }), !item.keyEquivalent.isEmpty else { return nil }
            return CommandBinding(item).label
        }
        return MenuShortcut.find(action: menuAction, tag: menuTag, in: NSApp.mainMenu)
    }
}

// @lat: [[lat.md/architecture/commands#Command shortcuts]]
@MainActor enum MenuShortcut {
    static func items(in menu: NSMenu?) -> [NSMenuItem] {
        (menu?.items ?? []).flatMap { [$0] + items(in: $0.submenu) }
    }

    static func find(action: Selector, tag: Int = 0, in menu: NSMenu?) -> String? {
        for item in menu?.items ?? [] {
            if item.action == action, item.tag == tag, !item.isHidden, !item.keyEquivalent.isEmpty {
                return label(key: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask)
            }
            if let match = find(action: action, tag: tag, in: item.submenu) { return match }
        }
        return nil
    }

    static func label(key: String, modifiers: NSEvent.ModifierFlags) -> String {
        let symbols = [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        let prefix = symbols.filter { modifiers.contains($0.0) }.map(\.1).joined()
        let special = ["\r": "↩", "\t": "⇥", "\u{1b}": "⎋", " ": "Space", "\u{7f}": "⌫",
                       "\u{f700}": "↑", "\u{f701}": "↓", "\u{f702}": "←", "\u{f703}": "→",
                       "\u{f728}": "⌦"]
        if let scalar = key.unicodeScalars.first, key.unicodeScalars.count == 1,
           (0xf704...0xf726).contains(scalar.value) {
            return prefix + "F\(scalar.value - 0xf704 + 1)"
        }
        return prefix + (special[key] ?? key.uppercased())
    }
}
