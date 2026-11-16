import AppKit

// @lat: [[lat.md/architecture/ai#Chat composer]]
enum ChatInputKey: String, CaseIterable, Identifiable {
    case enter, commandEnter, optionEnter, shiftEnter
    var id: String { rawValue }
    var title: String {
        switch self {
        case .enter: "Enter"
        case .commandEnter: "⌘ Enter"
        case .optionEnter: "⌥ Enter"
        case .shiftEnter: "⇧ Enter"
        }
    }
    var sendsByDefault: Bool { self == .enter || self == .commandEnter }
    init?(event: NSEvent) {
        guard event.keyCode == 36 || event.keyCode == 76 else { return nil }
        switch event.modifierFlags.intersection([.command, .shift, .option, .control]) {
        case []: self = .enter
        case .command: self = .commandEnter
        case .option: self = .optionEnter
        case .shift: self = .shiftEnter
        default: return nil
        }
    }
}
