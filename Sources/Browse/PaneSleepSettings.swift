import Network
import SwiftUI

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

    func keepsAwake(_ host: String) -> Bool {
        if keepAwakeHosts.contains(host) { return true }
        guard IPv4Address(host) == nil, !host.hasPrefix("[") else { return false }
        return keepAwakeHosts.contains { domain in
            host.hasSuffix("." + domain) && IPv4Address(domain) == nil
        }
    }

    func keepAwake(_ host: String, enabled: Bool) {
        if enabled { keepAwakeHosts.insert(host) } else { keepAwakeHosts.remove(host) }
    }
}

struct PaneSleepSettings: View {
    @ObservedObject var settings: PaneSleepPreferences
    @ViewState private var website = ""
    @ViewState private var editingWebsite = false
    @FocusState private var websiteFocused: Bool

    static func allowsHostnameCharacters(_ input: String) -> Bool {
        input.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".") }
    }

    static func hostname(from input: String) -> String? {
        guard allowsHostnameCharacters(input) else { return nil }
        let host = input.hasSuffix(".") ? input.dropLast() : input[...]
        guard !host.isEmpty, host.count <= 253 else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 && $0.first != "-" && $0.last != "-" }) else {
            return nil
        }
        return host.lowercased()
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
                LabeledContent("Website to keep awake") {
                    if editingWebsite {
                        TextField("Website to keep awake", text: $website, prompt: Text("example.com"))
                            .labelsHidden()
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: website) { previous, proposed in
                                if !Self.allowsHostnameCharacters(proposed) { website = previous }
                            }
                            .focused($websiteFocused)
                            .background(SettingsFieldFocusBoundary { editingWebsite = false })
                            .onAppear {
                                DispatchQueue.main.async {
                                    if editingWebsite { websiteFocused = true }
                                }
                            }
                            .onChange(of: websiteFocused) { _, focused in
                                if !focused { editingWebsite = false }
                            }
                            .onSubmit(addWebsite)
                            .onExitCommand { editingWebsite = false }
                    } else {
                        Button {
                            editingWebsite = true
                        } label: {
                            Text(website.isEmpty ? "example.com" : website)
                                .foregroundStyle(website.isEmpty ? .secondary : .primary)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Website to keep awake")
                        .accessibilityValue(website)
                    }
                }
                Button("Add", action: addWebsite).disabled(Self.hostname(from: website) == nil)
            }
        } header: { Text("Memory") } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: "Enter a hostname using letters, numbers, hyphens, and dots. Adding example.com keeps it and all its subdomains awake, including www.example.com.")
                Text("Eligible background panes sleep after 30 minutes, sooner in Low Power Mode or under memory pressure. Reload an existing page to include it in the experiment. Sleeping pages reload when revisited.")
            }
        }
    }
    private func addWebsite() {
        guard let hostname = Self.hostname(from: website) else { return }
        settings.keepAwake(hostname, enabled: true)
        website = ""
        editingWebsite = false
    }
}
