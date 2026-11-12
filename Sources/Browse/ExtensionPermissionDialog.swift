import AppKit
import SwiftUI

private typealias PermissionViewState<Value> = SwiftUI.State<Value>

// @lat: [[lat.md/architecture/extensions/lifecycle#Extension permission presentation]]
struct ExtensionPermissionSummary {
    struct Item: Identifiable {
        let title: String
        let symbol: String
        var id: String { title }
    }

    let websites: [String]
    let capabilities: [Item]
    let details: [String]

    init(details: [String]) {
        self.details = Array(Set(details)).sorted()
        var websites: [String] = []
        var capabilities: [Item] = []
        for permission in self.details {
            if permission == "<all_urls>" {
                websites.append("All websites")
            } else if permission.contains("://") {
                // Preserve scheme, wildcard, and path restrictions for review.
                websites.append(permission)
            } else {
                let item = Self.descriptions[permission]
                    ?? Item(title: "Additional permission: \(permission)", symbol: "puzzlepiece.extension")
                if !capabilities.contains(where: { $0.id == item.id }) { capabilities.append(item) }
            }
        }
        self.websites = websites
        self.capabilities = capabilities
    }

    private static let descriptions: [String: Item] = [
        "activeTab": .init(title: "Access the current tab when you use the extension", symbol: "cursorarrow.click"),
        "tabs": .init(title: "Read tab titles and addresses", symbol: "rectangle.on.rectangle"),
        "scripting": .init(title: "Run scripts on websites you allow", symbol: "curlybraces"),
        "declarativeNetRequest": .init(title: "Block or redirect network requests using filtering rules", symbol: "line.3.horizontal.decrease.circle"),
        "declarativeNetRequestWithHostAccess": .init(title: "Filter network requests on websites you allow", symbol: "line.3.horizontal.decrease.circle"),
        "declarativeNetRequestFeedback": .init(title: "Read which network filtering rules matched", symbol: "list.bullet.rectangle"),
        "webRequest": .init(title: "Observe network requests on websites you allow", symbol: "network"),
        "webRequestBlocking": .init(title: "Block or change network requests on websites you allow", symbol: "network"),
        "webNavigation": .init(title: "Observe navigation on websites you allow", symbol: "arrow.triangle.branch"),
        "nativeMessaging": .init(title: "Communicate with companion apps on your Mac", symbol: "desktopcomputer"),
        "storage": .init(title: "Save extension settings and data", symbol: "externaldrive"),
        "unlimitedStorage": .init(title: "Store extension data without the usual quota", symbol: "externaldrive.badge.plus"),
        "alarms": .init(title: "Schedule background tasks", symbol: "clock"),
        "notifications": .init(title: "Show notifications", symbol: "bell"),
        "cookies": .init(title: "Read and change cookies on websites you allow", symbol: "person.crop.circle"),
        "history": .init(title: "Read and change browsing history", symbol: "clock.arrow.circlepath"),
        "bookmarks": .init(title: "Read and change bookmarks", symbol: "bookmark"),
        "downloads": .init(title: "Manage downloads", symbol: "arrow.down.circle"),
        "clipboardRead": .init(title: "Read your clipboard", symbol: "doc.on.clipboard"),
        "clipboardWrite": .init(title: "Write to your clipboard", symbol: "doc.on.clipboard"),
        "contextMenus": .init(title: "Add items to context menus", symbol: "list.bullet"),
        "menus": .init(title: "Add items to context menus", symbol: "list.bullet"),
        "privacy": .init(title: "Access supported browser privacy settings", symbol: "hand.raised"),
        "browserSettings": .init(title: "Access supported browser settings", symbol: "gearshape"),
        "idle": .init(title: "Detect when your Mac is idle", symbol: "moon"),
        "management": .init(title: "Access information about installed extensions", symbol: "puzzlepiece.extension")
    ]
}

@MainActor
struct ExtensionPermissionView: View {
    let name: String
    let icon: NSImage?
    let summary: ExtensionPermissionSummary
    let sessionOnly: Bool
    let respond: (Bool) -> Void
    @PermissionViewState<Bool> private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                Group {
                    if let icon { Image(nsImage: icon).resizable().scaledToFit() }
                    else { Image(systemName: "puzzlepiece.extension.fill").font(.system(size: 32)).foregroundStyle(.secondary) }
                }.frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Allow access in Bend?").font(.title2.weight(.semibold))
                    Text(name).font(.headline).lineLimit(3)
                    Text(sessionOnly ? "This extension is requesting access for this session." : "Review what this extension will be allowed to do.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !summary.websites.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Website access").font(.headline)
                            Label("Read and change data on these websites", systemImage: "globe")
                                .font(.callout)
                            ForEach(summary.websites, id: \.self) { website in
                                Text(website).font(.callout.weight(.medium))
                                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                    .padding(.leading, 26)
                            }
                        }
                    }
                    if !summary.capabilities.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Capabilities").font(.headline)
                            ForEach(summary.capabilities) { item in
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: item.symbol).foregroundStyle(.secondary).frame(width: 18)
                                    Text(item.title).fixedSize(horizontal: false, vertical: true)
                                }.font(.callout)
                            }
                        }
                    }
                    DisclosureGroup("Technical details", isExpanded: $showsDetails) {
                        Text(summary.details.joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                    }.font(.caption).foregroundStyle(.secondary)
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: .infinity)
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                Text("You can turn off this extension in Bend’s Extensions settings.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Don’t Allow") { respond(false) }.keyboardShortcut(.cancelAction)
                    Button("Allow") { respond(true) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }.controlSize(.large)
            }.padding(24)
        }.frame(width: 520, height: 580)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

@MainActor
final class ExtensionPermissionDialog: NSObject, NSWindowDelegate {
    private var allowed = false

    func run(name: String, details: [String], icon: NSImage?, sessionOnly: Bool) -> Bool {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 580),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Extension permissions"
        panel.titleVisibility = .hidden
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: ExtensionPermissionView(
            name: name, icon: icon, summary: .init(details: details), sessionOnly: sessionOnly,
            respond: { [weak self] value in self?.allowed = value; NSApp.stopModal() }))
        panel.center()
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
        panel.close()
        return allowed
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.stopModal()
        return true
    }
}
