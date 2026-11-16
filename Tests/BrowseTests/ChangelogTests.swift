import AppKit
import SwiftUI
import Testing
import BrowseCore
@testable import Browse

private func releaseBundle(root: URL, version: String, build: String) throws -> Bundle {
    let app = root.appendingPathComponent(UUID().uuidString).appendingPathComponent("Bend.app")
    try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
    let plist: [String: Any] = ["CFBundleIdentifier": AppProfile.production.bundleIdentifier,
                              "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version, "CFBundleVersion": build]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
    return try #require(Bundle(url: app))
}

// @lat: [[lat.md/tests/updates-tests#Changelog content and routing]]
@Test @MainActor func changelogContentAndRouting() async throws {
    _ = NSApplication.shared
    let markdown = """
    # Changelog
    Internal maintenance instructions.
    ## v1.2.0
    ### Added
    - **Native** improvements and [details](https://example.com/notes).
    ```
    ## v9.9.9
    ```
    ## v1.1.0
    Earlier release.
    """
    let changelog = Changelog(markdown: markdown, releaseDates: ["1.2.0": "2026-11-15"])
    #expect(changelog.releases.map(\.version) == ["1.2.0", "1.1.0"])
    let date = try #require(changelog.releases[0].date)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    #expect(calendar.dateComponents([.year, .month, .day], from: date) == DateComponents(year: 2026, month: 11, day: 15))
    #expect(changelog.releases[1].date == nil)
    for invalid in ["2026-02-30", "2026-1-5", "garbage", ""] {
        #expect(Changelog(markdown: markdown, releaseDates: ["1.2.0": invalid]).releases[0].date == nil)
    }
    #expect(changelog.releases[0].markdown.contains("## v9.9.9"))
    #expect(!changelog.releases[0].markdown.contains("maintenance"))
    let rendered = ChangelogView.document(changelog.releases[0].markdown)
    #expect(rendered.string.contains("Native improvements"))
    #expect(!rendered.string.contains("**Native**"))
    let link = (rendered.string as NSString).range(of: "details")
    #expect(rendered.attribute(.link, at: link.location, effectiveRange: nil) != nil)
    #expect(AddressResolver.resolve("bend://log")?.absoluteString == "bend://log")
    #expect(AddressResolver.nativePageTitle("bend://log") == "What’s New")
    #expect(AddressResolver.resolve("bend://unknown") == nil)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Changelog-\(UUID())")
    let store = BrowserStore(sessionFile: root.appendingPathComponent("session.json"), persistentExtensions: false)
    defer { store.stopWindow(); try? FileManager.default.removeItem(at: root) }
    let oldTabs = store.session.workspaces.flatMap(\.tabs).map(\.id)
    store.showChangelog()
    let tab = store.selectedTab
    #expect(tab.title == "What’s New")
    let page = try #require(tab.pages.first)
    let controller = store.controller(for: page)
    #expect(controller.title == "What’s New" && controller.isStartPage)
    #expect(controller.error == nil)
    store.select(oldTabs[0])
    store.showChangelog()
    #expect(store.selectedTab.id == tab.id)
    #expect(store.session.workspaces.flatMap(\.tabs).count == oldTabs.count + 1)
    #expect(store.history.visits.isEmpty)
    let decoded = try JSONDecoder().decode(BrowserSession.self, from: JSONEncoder().encode(store.session))
    #expect(decoded.workspaces.flatMap(\.tabs).contains { $0.pages.contains { $0.address == "bend://log" } })
    let bundle = try releaseBundle(root: root, version: "1.2.0", build: "12")
    try markdown.write(to: bundle.bundleURL.appendingPathComponent("Contents/Resources/CHANGELOG.md"), atomically: true, encoding: .utf8)
    let datesURL = bundle.bundleURL.appendingPathComponent("Contents/Resources/release-dates.json")
    try JSONEncoder().encode(["1.2.0": "2026-11-15"]).write(to: datesURL)
    #expect(Changelog.load(bundle: bundle).releases.map(\.version) == ["1.2.0", "1.1.0"])
    #expect(Changelog.load(bundle: bundle).releases[0].date == date)
    try Data("invalid JSON".utf8).write(to: datesURL)
    #expect(Changelog.load(bundle: bundle).releases[0].date == nil)
}

// @lat: [[lat.md/tests/updates-tests#Post-update release notes]]
@Test @MainActor func postUpdateReleaseNotes() throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReleaseLaunch-\(UUID())")
    let suite = "ReleaseLaunch-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    let windows = BrowserWindows(root: root, persistentExtensions: false)
    defer { windows.prepareToQuit(); for item in windows.windows { item.window.close() }; defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    windows.restore(show: false)
    let delegate = AppDelegate(browserWindows: windows)
    func tracker(_ version: String, _ build: String, profile: AppProfile = .production) throws -> WhatsNewTracker {
        WhatsNewTracker(profile: profile, bundle: try releaseBundle(root: root, version: version, build: build), defaults: defaults)
    }
    #expect(try !tracker("0.7.0", "700").consumeUpgrade()) // First launch establishes a baseline.
    let baseline = defaults.dictionary(forKey: WhatsNewTracker.preferenceKey) as? [String: String]
    #expect(try !tracker("0.8.0", "800", profile: .debug).consumeUpgrade())
    #expect(defaults.dictionary(forKey: WhatsNewTracker.preferenceKey) as? [String: String] == baseline)
    #expect(try !tracker("bad", "800").consumeUpgrade())
    #expect(try !tracker("0.7.0", "700").consumeUpgrade())
    let regular = try #require(windows.windows.first)
    let existing = regular.store.session.workspaces.flatMap(\.tabs).map(\.id)
    let privateWindow = windows.newPrivateWindow(show: false)
    delegate.showReleaseNotesIfUpdated(tracker: try tracker("0.8.0", "800"), show: false)
    #expect(regular.store.selectedTab.pages.first?.address == "bend://log")
    #expect(!privateWindow.store.selectedTab.pages.contains { $0.address == "bend://log" })
    #expect(existing.allSatisfy { id in regular.store.session.workspaces.flatMap(\.tabs).contains { $0.id == id } })
    let logTab = regular.store.selectedTab.id
    regular.store.select(existing[0])
    delegate.showReleaseNotesIfUpdated(tracker: try tracker("0.8.0", "800"), show: false)
    #expect(regular.store.selectedTab.id == existing[0]) // Ordinary restart stays quiet.
    delegate.showReleaseNotesIfUpdated(tracker: try tracker("0.8.0", "801"), show: false)
    #expect(regular.store.selectedTab.id == logTab) // Reuse, don't duplicate a restored log tab.
    #expect(try !tracker("0.7.0", "999").consumeUpgrade()) // Rollback doesn't lower the high-water mark.
    #expect(try !tracker("0.8.0", "801").consumeUpgrade())
    #expect(try tracker("0.10.0", "1").consumeUpgrade()) // Numeric version order; build may reset.
}

@Test @MainActor func changelogPageLayout() async throws {
    _ = NSApplication.shared
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let source = try String(contentsOf: repo.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)
    let version = try String(contentsOf: repo.appendingPathComponent("VERSION"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    let dates = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: repo.appendingPathComponent(".changes/release-dates.json")))
    let changelog = Changelog(markdown: source, releaseDates: dates)
    #expect(changelog.releases.first?.version == version)
    #expect(changelog.releases.last?.version == "0.1.0")
    let host = NSHostingView(rootView: ChangelogView(changelog: changelog, installedVersion: version, openLink: { _ in }))
    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 920, height: 780), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }
    for width in [920.0, 360.0] {
        window.setContentSize(NSSize(width: width, height: 780))
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        #expect(abs(host.frame.width - width) < 0.01)
        func textViews(_ view: NSView) -> [NSTextView] {
            (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews)
        }
        let texts = textViews(host)
        #expect(texts.count == changelog.releases.count)
        for text in texts {
            let container = try #require(text.textContainer)
            let layout = try #require(text.layoutManager)
            layout.ensureLayout(for: container)
            #expect(text.frame.height + 1 >= layout.usedRect(for: container).height)
        }
        if let path = ProcessInfo.processInfo.environment["BEND_CHANGELOG_SNAPSHOT"],
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path + "-\(Int(width)).png"))
        }
    }
}
