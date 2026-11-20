import AppKit
import SwiftUI

private typealias ViewState<Value> = SwiftUI.State<Value>

struct CommandBinding: Codable, Equatable {
    let key: String
    let flags: UInt

    init(_ key: String, _ modifiers: NSEvent.ModifierFlags) {
        self.key = key.lowercased()
        var flags = modifiers.intersection([.command, .option, .control, .shift])
        if key != key.lowercased() { flags.insert(.shift) }
        self.flags = flags.rawValue
    }

    @MainActor var label: String {
        MenuShortcut.label(key: key, modifiers: NSEvent.ModifierFlags(rawValue: flags))
    }

    var keyboardShortcut: KeyboardShortcut? {
        guard key.count == 1, let character = key.first else { return nil }
        let mask = NSEvent.ModifierFlags(rawValue: flags)
        var modifiers: EventModifiers = []
        if mask.contains(.command) { modifiers.insert(.command) }
        if mask.contains(.option) { modifiers.insert(.option) }
        if mask.contains(.control) { modifiers.insert(.control) }
        if mask.contains(.shift) { modifiers.insert(.shift) }
        return KeyboardShortcut(KeyEquivalent(character), modifiers: modifiers, localization: .custom)
    }

    @MainActor init(_ item: NSMenuItem) {
        self.init(item.keyEquivalent, item.keyEquivalentModifierMask)
    }

    @MainActor func apply(to item: NSMenuItem) {
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: flags)
    }
}

@MainActor
final class CommandShortcuts: ObservableObject {
    private let defaults: UserDefaults
    private let storageKey = "commandShortcutOverrides"
    private var original: [String: CommandBinding] = [:]
    private var items: [String: NSMenuItem] = [:]
    private weak var menu: NSMenu?
    private var attempted: (id: String, binding: CommandBinding)?
    @Published private(set) var overrides: [String: CommandBinding]

    init(defaults: UserDefaults = AppProfile.current.defaults) {
        self.defaults = defaults
        overrides = defaults.data(forKey: storageKey).flatMap {
            try? JSONDecoder().decode([String: CommandBinding].self, from: $0)
        } ?? [:]
    }

    func install(commands: [PopupCommand], menu: NSMenu, extraMenu: NSMenu, target: AppDelegate) {
        self.menu = menu
        attempted = nil
        items.removeAll()
        original.removeAll()
        let nativeItems = MenuShortcut.items(in: menu)
        for command in commands {
            let item: NSMenuItem
            if let action = command.menuAction, let existing = nativeItems.first(where: {
                !$0.isHidden && $0.action == action && $0.tag == command.menuTag
            }) {
                item = existing
            } else {
                item = extraMenu.addItem(withTitle: command.title, action: #selector(AppDelegate.runPaletteShortcut(_:)), keyEquivalent: "")
                item.representedObject = command.id
                item.target = target
            }
            items[command.id] = item
            original[command.id] = CommandBinding(item)
            overrides[command.id]?.apply(to: item)
        }
        refreshConflicts()
    }

    struct Conflict {
        let source: String
        let owner: String?
        let ownerItem: NSMenuItem
        let binding: CommandBinding
    }

    private func owners(of binding: CommandBinding, excluding item: NSMenuItem, in menuItems: [NSMenuItem]) -> [NSMenuItem] {
        guard !binding.key.isEmpty else { return [] }
        return menuItems.filter {
            $0 !== item && (!$0.isHidden || $0.allowsKeyEquivalentWhenHidden) && CommandBinding($0) == binding
        }
    }

    @Published private(set) var conflicts: [Conflict] = []

    var newTabBinding: CommandBinding? {
        MenuShortcut.items(in: menu).first { !$0.isHidden && $0.action == #selector(AppDelegate.newTab) }.map(CommandBinding.init)
    }

    func binding(for id: String) -> CommandBinding? {
        guard let item = items[id], !item.keyEquivalent.isEmpty else { return nil }
        return CommandBinding(item)
    }

    func label(for id: String) -> String? {
        binding(for: id)?.label
    }

    func dismissAttemptedConflict() {
        guard attempted != nil else { return }
        attempted = nil
        refreshConflicts()
    }

    func refreshConflicts() {
        let menuItems = MenuShortcut.items(in: menu)
        conflicts = items.flatMap { id, item in
            let current = CommandBinding(item)
            var bindings = [current]
            if let attempted, attempted.id == id, attempted.binding != current { bindings.append(attempted.binding) }
            return bindings.flatMap { binding in
                owners(of: binding, excluding: item, in: menuItems).map { owner in
                    Conflict(source: id, owner: items.first { $0.value === owner }?.key,
                             ownerItem: owner, binding: binding)
                }
            }
        }
    }

    // A nil binding restores the installed default, which can itself be unassigned.
    func update(_ id: String, to binding: CommandBinding?) -> String? {
        guard let item = items[id], let standard = original[id] else { return "Command unavailable." }
        let next = binding ?? standard
        let menuItems = MenuShortcut.items(in: menu)
        if let owner = owners(of: next, excluding: item, in: menuItems).first {
            attempted = (id, next)
            refreshConflicts()
            return "\(next.label) is already used by \(owner.title)."
        }
        next.apply(to: item)
        attempted = nil
        overrides[id] = next == standard ? nil : next
        refreshConflicts()
        defaults.set(try? JSONEncoder().encode(overrides), forKey: storageKey)
        return nil
    }
}

/// Settings only needs presentation data, so a closed sheet never retains browser actions.
struct ShortcutEntry {
    let id: String
    let title: String
    let detail: String
    let icon: String
    let group: ShortcutGroup

    @MainActor init(_ command: PopupCommand) {
        id = command.id
        title = command.shortcutTitle ?? command.title
        detail = command.detail
        icon = command.icon
        group = command.group
    }
}

struct ShortcutsSettingsView: View {
    @ObservedObject var shortcuts: CommandShortcuts
    let commands: [ShortcutEntry]
    @ViewState private var query = ""
    @ViewState private var recording: String?
    @ViewState private var message: String?
    @ViewState private var messageID: String?

    static func matches(_ command: ShortcutEntry, shortcut: String?, query: String) -> Bool {
        let label = shortcut ?? "Unassigned"
        let names = label.replacingOccurrences(of: "⌃", with: "Control Ctrl ")
            .replacingOccurrences(of: "⌥", with: "Option Opt Alt ")
            .replacingOccurrences(of: "⇧", with: "Shift ")
            .replacingOccurrences(of: "⌘", with: "Command Cmd ")
        let text = "\(command.group.rawValue) \(command.title) \(command.detail) \(label) \(names)"
        if query.contains("+") {
            let parts = query.lowercased().components(separatedBy: "+").map { $0.trimmingCharacters(in: .whitespaces) }
            let symbols = ["command": "⌘", "cmd": "⌘", "control": "⌃", "ctrl": "⌃",
                           "option": "⌥", "alt": "⌥", "opt": "⌥", "shift": "⇧"]
            if parts.count > 1, let key = parts.last, !key.isEmpty,
               parts.dropLast().allSatisfy({ symbols[$0] != nil }) {
                let modifiers = Set(parts.dropLast().compactMap { symbols[$0] })
                let prefix = ["⌃", "⌥", "⇧", "⌘"].filter(modifiers.contains).joined()
                return label.caseInsensitiveCompare(prefix + key) == .orderedSame
            }
        }
        let terms = query.split(whereSeparator: { $0.isWhitespace })
        return terms.allSatisfy { text.localizedCaseInsensitiveContains(String($0)) }
    }

    var body: some View {
        let conflicts = shortcuts.conflicts
        let matches = Set(commands.filter { query.isEmpty || Self.matches($0, shortcut: shortcuts.label(for: $0.id), query: query) }.map(\.id))
        let visibleConflicts = conflicts.filter {
            matches.contains($0.source) || $0.owner.map(matches.contains) == true ||
                (!query.isEmpty && $0.ownerItem.title.localizedCaseInsensitiveContains(query))
        }
        let menuOwners = Set(visibleConflicts.filter { $0.owner == nil }.map(\.ownerItem))
            .sorted { $0.title < $1.title }
        let highlighted = Set(visibleConflicts.map(\.source) + visibleConflicts.compactMap(\.owner))
        let filteredCommands = commands.filter {
            highlighted.contains($0.id) || matches.contains($0.id)
        }
        Form {
            Section {
                TextField("Search shortcuts", text: $query, prompt: Text("Search shortcuts"))
                    .labelsHidden()
                    .accessibilityLabel("Search shortcuts")
            }
            ForEach(ShortcutGroup.allCases, id: \.self) { group in
                let rows = filteredCommands.filter { $0.group == group }
                if !rows.isEmpty || (group == .generalUI && !menuOwners.isEmpty) {
                    Section(group.rawValue) {
                        ForEach(rows, id: \.id) { command in
                            commandRow(command, conflict: visibleConflicts.first { $0.source == command.id || $0.owner == command.id })
                        }
                        if group == .generalUI {
                            ForEach(menuOwners, id: \.self) { owner in
                                LabeledContent(owner.title, value: CommandBinding(owner).label)
                                    .fontWeight(.semibold)
                                    .listRowBackground(Color.orange.opacity(0.14))
                            }
                        }
                    }
                }
            }
            if filteredCommands.isEmpty {
                Text("No matching commands").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onDisappear { shortcuts.dismissAttemptedConflict() }
        .onChange(of: query) { recording = nil }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in recording = nil }
    }

    private func commandRow(_ command: ShortcutEntry, conflict: CommandShortcuts.Conflict?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Image(systemName: command.icon)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text(command.title)
                    .fontWeight(conflict == nil ? .regular : .semibold)
                Spacer()
                Button(recording == command.id ? "Press shortcut…" : shortcuts.label(for: command.id) ?? "Record Shortcut") {
                    message = nil
                    messageID = nil
                    recording = recording == command.id ? nil : command.id
                }
                .accessibilityLabel("Change shortcut for \(command.title)")
                Button("Reset") { save(command.id, nil) }
                    .disabled(shortcuts.overrides[command.id] == nil)
                    .help("Restore the default shortcut")
            }
            if recording == command.id {
                Text("Press a shortcut. Delete clears it. Escape cancels.")
                    .foregroundStyle(.secondary)
                    .background(ShortcutCapture { event in record(event, id: command.id) })
            }
            if let notice = messageID == command.id ? message : nil {
                Text(notice).foregroundStyle(.orange)
            }
            if let conflict {
                let otherID = conflict.source == command.id ? conflict.owner : conflict.source
                let other = commands.first { $0.id == otherID }?.title ?? conflict.ownerItem.title
                Text("\(conflict.binding.label) conflicts with \(other)").foregroundStyle(.orange)
            }
        }
        .listRowBackground(conflict == nil ? nil : Color.orange.opacity(0.14))
    }

    private func record(_ event: NSEvent, id: String) {
        if event.keyCode == 53 { recording = nil; messageID = nil; return }
        let modifiers = event.modifierFlags
        if event.keyCode == 51, modifiers.intersection([.control, .option, .command, .shift]).isEmpty {
            save(id, CommandBinding("", []))
            return
        }
        guard let key = event.characters(byApplyingModifiers: []), key.count == 1,
              !modifiers.intersection([.command, .option, .control]).isEmpty ||
                key.unicodeScalars.first.map({ (0xf704...0xf726).contains($0.value) }) == true else {
            messageID = id
            message = "Include Command, Option, or Control, or use a function key."
            return
        }
        save(id, CommandBinding(key, modifiers))
    }

    private func save(_ id: String, _ binding: CommandBinding?) {
        let error = shortcuts.update(id, to: binding)
        message = shortcuts.conflicts.contains { $0.source == id } ? nil : error
        messageID = message == nil ? nil : id
        recording = nil
    }
}

/// Capture before AppKit resolves menu key equivalents, only in the recording window.
private struct ShortcutCapture: NSViewRepresentable {
    let onKey: (NSEvent) -> Void

    final class CaptureView: NSView {
        var monitor: Any?
        var onKey: ((NSEvent) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, window.isKeyWindow, event.window === window else { return event }
                if !event.isARepeat { self.onKey?(event) }
                return nil
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        }
    }

    func makeNSView(context: Context) -> CaptureView { CaptureView() }
    func updateNSView(_ view: CaptureView, context: Context) { view.onKey = onKey }
    static func dismantleNSView(_ view: CaptureView, coordinator: ()) { view.stop() }
}
