import AppKit
import SwiftUI

// @lat: [[architecture#Default browser]]
@MainActor
final class DefaultBrowser: ObservableObject {
    @Published private(set) var isDefault = false
    @Published private(set) var isRequesting = false
    @Published private(set) var error: String?

    private let applicationURL: URL
    private let bundleIdentifier: String?
    private let handler: (URL) -> String?
    private let setHandler: (URL, String) async throws -> Void
    private static let schemes = ["https", "http"]

    init(applicationURL: URL = Bundle.main.bundleURL, bundleIdentifier: String? = Bundle.main.bundleIdentifier,
         handler: @escaping (URL) -> String? = { url in
             NSWorkspace.shared.urlForApplication(toOpen: url).flatMap { Bundle(url: $0)?.bundleIdentifier }
         },
         setHandler: @escaping (URL, String) async throws -> Void = { app, scheme in
             try await NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: scheme)
         }) {
        self.applicationURL = applicationURL
        self.bundleIdentifier = bundleIdentifier
        self.handler = handler
        self.setHandler = setHandler
        refresh()
    }

    private func handles(_ scheme: String) -> Bool {
        guard let bundleIdentifier else { return false }
        return handler(URL(string: "\(scheme)://example.com")!) == bundleIdentifier
    }

    func refresh() {
        let current = Self.schemes.allSatisfy { handles($0) }
        if isDefault != current { isDefault = current }
    }

    func makeDefault() async {
        guard !isRequesting else { return }
        isRequesting = true
        error = nil
        defer { refresh(); isRequesting = false }
        do {
            // macOS may update both web schemes in one confirmation. Recheck
            // before requesting the second so we don't show a redundant prompt.
            for scheme in Self.schemes where !handles(scheme) {
                try await setHandler(applicationURL, scheme)
            }
        } catch {
            let failure = error as NSError
            let cancelled = (failure.domain == NSCocoaErrorDomain && failure.code == NSUserCancelledError)
                || (failure.domain == NSOSStatusErrorDomain && failure.code == -128)
            if !cancelled { self.error = failure.localizedDescription }
        }
    }
}

struct DefaultBrowserSettingsSection: View {
    @StateObject private var browser = DefaultBrowser()

    var body: some View {
        Section("Default browser") {
            HStack {
                Text(browser.isDefault ? "Bend is your default web browser" : "Make Bend your default web browser")
                Spacer()
                if browser.isDefault {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
                        .accessibilityLabel("Default browser")
                } else {
                    Button(browser.isRequesting ? "Setting…" : "Make Default…") {
                        Task { await browser.makeDefault() }
                    }
                    .disabled(browser.isRequesting)
                }
            }
            if let error = browser.error {
                Text(error).font(.callout).foregroundStyle(.secondary)
            }
        }
        .onAppear { browser.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            browser.refresh()
        }
    }
}
