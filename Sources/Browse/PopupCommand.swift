import AppKit

/// A command's availability is checked again immediately before execution.
@MainActor
struct PopupCommand {
    let id: String
    let title: String
    let detail: String
    let icon: String
    var isEnabled: Bool = true
    let perform: () -> Void
}
