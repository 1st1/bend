import SwiftUI
import BrowseCore

private typealias ViewState<Value> = SwiftUI.State<Value>

@MainActor
final class PaneSleepPreferences: ObservableObject {
    static let shared = PaneSleepPreferences(defaults: AppProfile.current.defaults)
    private let defaults: UserDefaults
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "PaneSleepEnabled") } }
    @Published private(set) var keepAwakeHosts: Set<String> {
        didSet { defaults.set(keepAwakeHosts.sorted(), forKey: "PaneSleepKeepAwakeHosts") }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: "PaneSleepEnabled")
        keepAwakeHosts = Set(defaults.stringArray(forKey: "PaneSleepKeepAwakeHosts") ?? [])
    }

    func keepAwake(_ host: String, enabled: Bool) {
        if enabled { keepAwakeHosts.insert(host) } else { keepAwakeHosts.remove(host) }
    }
}

struct PaneSleepSettings: View {
    @ObservedObject var settings: PaneSleepPreferences
    @ViewState private var website = ""
    private var hostname: String? {
        let value = website.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return URL(string: value.contains("://") ? value : "https://\(value)").flatMap(WebsiteSettings.hostname(for:))
    }
    var body: some View {
        Section {
            Toggle("Sleep inactive panes", isOn: $settings.enabled)
            ForEach(settings.keepAwakeHosts.sorted(), id: \.self) { host in
                HStack {
                    Text(host)
                    Spacer()
                    Button("Remove", systemImage: "minus.circle") { settings.keepAwake(host, enabled: false) }
                        .labelStyle(.iconOnly).help("Allow \(host) to sleep")
                }
            }
            HStack {
                TextField("Website to keep awake", text: $website).onSubmit(addWebsite)
                Button("Add", action: addWebsite).disabled(hostname == nil)
            }
        } header: { Text("Memory") } footer: {
            Text("Eligible background panes sleep after 30 minutes, sooner in Low Power Mode or under memory pressure. Reload an existing page to include it in the experiment. Sleeping pages reload when revisited. Exceptions apply to the exact hostname.")
        }
    }
    private func addWebsite() {
        guard let hostname else { return }
        settings.keepAwake(hostname, enabled: true)
        website = ""
    }
}
