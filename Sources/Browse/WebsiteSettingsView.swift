import SwiftUI
import AppKit
import BrowseCore
import WebKit

private typealias ViewState<Value> = SwiftUI.State<Value>

// @lat: [[lat.md/architecture/settings#Website settings]]
struct WebsiteSettingsView: View {
    @ObservedObject var settings: WebsiteSettingsStore
    @ViewState private var query = ""
    @ViewState private var showsFilter = false
    @FocusState private var filterFocused: Bool

    private var hosts: [String] {
        settings.values.zoomByHost.keys.sorted().filter {
            query.isEmpty || $0.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        Form {
            if let error = settings.errorMessage {
                Section {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                    Button("Retry") { settings.reload() }
                }
            }
            Section("Security") {
                Toggle("Warn when visiting a fraudulent website", isOn: preference(\.warnFraudulentSites))
                Text("Uses macOS WebKit’s built-in fraudulent website warnings.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Warn before connecting to a website over HTTP", isOn: preference(\.warnHTTP))
                Text("Tries HTTPS first and shows a warning if a secure connection cannot be established.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Enable JavaScript", isOn: preference(\.javaScriptEnabled))
            } header: {
                Text("Web content")
            } footer: {
                Text("Changes apply when you reload a page or navigate. Extension pages keep JavaScript enabled.")
            }
            Section {
                zoomPicker("When visiting other websites", selection: Binding(
                    get: { settings.values.defaultZoom }, set: { settings.setDefaultZoom($0) }))
            } header: {
                Text("Page zoom")
            } footer: {
                Text("Zoom is remembered automatically for each website. Different subdomains keep separate settings.")
            }
            Section {
                if settings.values.zoomByHost.isEmpty {
                    Text("No website overrides. Use ⌘+ or ⌘− on a webpage to save its zoom.")
                        .foregroundStyle(.secondary)
                } else {
                    filterControl
                    if hosts.isEmpty {
                        Text("No matching websites").foregroundStyle(.secondary)
                    }
                    ForEach(hosts, id: \.self) { host in
                        HStack {
                            zoomPicker(host, selection: Binding(
                                get: { settings.values.zoomByHost[host] ?? settings.values.defaultZoom },
                                set: { settings.setZoom($0, forHost: host) }))
                            Button {
                                settings.removeOverride(for: host)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Use default zoom for \(host)")
                            .accessibilityLabel("Reset \(host) to default zoom")
                        }
                    }
                    Button("Reset All Websites to Default") { settings.removeAllOverrides() }
                }
            } header: {
                Text("Configured websites")
            } footer: {
                Text("Removing an override applies the default zoom. Changes update open pages in every window.")
            }
        }
        .formStyle(.grouped)
        .onChange(of: filterFocused) { _, focused in
            if !focused, query.isEmpty { showsFilter = false }
        }
        .onChange(of: settings.values.zoomByHost.isEmpty) { _, empty in
            if empty { query = ""; showsFilter = false; filterFocused = false }
        }
    }

    private func preference(_ key: WritableKeyPath<WebsiteSettings, Bool>) -> Binding<Bool> {
        Binding(get: { settings.values[keyPath: key] }, set: { settings.setPreference(key, $0) })
    }

    private var filterControl: some View {
        HStack {
            Spacer(minLength: 0)
            if showsFilter {
                TextField("Filter by name", text: $query)
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .focused($filterFocused)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(filterFocused ? Color.accentColor.opacity(0.65) : .primary.opacity(0.1))
                    }
                    .frame(width: 170)
                    .background(FilterFocusBoundary { filterFocused = false })
                    .onAppear {
                        // Wait for the native field to join the window's focus tree.
                        DispatchQueue.main.async {
                            if showsFilter { filterFocused = true }
                        }
                    }
                    .onSubmit { filterFocused = false }
                    .onExitCommand { filterFocused = false }
            } else {
                Button("Filter by name", systemImage: "line.3.horizontal.decrease") {
                    showsFilter = true
                }
                .buttonStyle(.borderless)
            }
        }
        .frame(height: 28)
    }

    private func zoomPicker(_ title: String, selection: Binding<Double>) -> some View {
        // Include a stored nonstandard value if a future version adds finer steps.
        let levels = Set(PageZoom.levels + [selection.wrappedValue]).sorted()
        return Picker(title, selection: selection) {
            ForEach(levels, id: \.self) { zoom in
                Text(zoom, format: .percent.precision(.fractionLength(0))).tag(zoom)
            }
        }
    }
}

// Native controls do not ordinarily resign their field editor when blank form
// space is clicked. Observe outside clicks without swallowing the target's event.
private struct FilterFocusBoundary: NSViewRepresentable {
    var onOutsideClick: () -> Void

    func makeNSView(context: Context) -> BoundaryView { BoundaryView() }
    func updateNSView(_ view: BoundaryView, context: Context) { view.onOutsideClick = onOutsideClick }
    static func dismantleNSView(_ view: BoundaryView, coordinator: ()) { view.stopMonitoring() }

    final class BoundaryView: NSView {
        var onOutsideClick: (() -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            NotificationCenter.default.addObserver(self, selector: #selector(windowResigned),
                name: NSWindow.didResignKeyNotification, object: window)
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                if !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                    self.onOutsideClick?()
                }
                return event
            }
        }

        @objc private func windowResigned() { onOutsideClick?() }

        func stopMonitoring() {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
