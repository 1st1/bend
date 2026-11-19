import AppKit
import Foundation
import Testing
import Sparkle
@testable import Browse

private func requiredLocation(of substring: String, in text: NSString) throws -> Int {
    let location = text.range(of: substring).location
    try #require(location != NSNotFound, "Missing release note text: \(substring)")
    return location
}

// @lat: [[lat.md/tests/updates-tests#Application updater isolation]]
@Test @MainActor func applicationUpdaterIsolation() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendUpdater-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("Bend.app")
    try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    let info: [String: Any] = ["CFBundleIdentifier": AppProfile.production.bundleIdentifier,
        "CFBundleName": "Bend", "CFBundleVersion": "12001", "CFBundleShortVersionString": "0.3.0",
        "CFBundlePackageType": "APPL"]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: app.appendingPathComponent("Contents/Info.plist"))
    let bundle = try #require(Bundle(url: app))
    let debug = AppUpdater(profile: .debug, bundle: bundle)
    debug.start()
    debug.checkForUpdates()
    #expect(!debug.isEnabled)
    #expect(!debug.canCheckForUpdates)
    #expect(debug.availableVersion == nil)
    #expect(!AppUpdater(profile: .production, bundle: .main).isEnabled)
    let production = AppUpdater(profile: .production, bundle: bundle)
    #expect(production.isEnabled)
    #expect(production.supportsGentleScheduledUpdateReminders)
    // Catch misspelled optional Objective-C callbacks, which silently suppress reminders or release-notes styling.
    for name in ["standardUserDriverShouldHandleShowingScheduledUpdate:andInImmediateFocus:",
                 "standardUserDriverWillHandleShowingUpdate:forUpdate:state:",
                 "standardUserDriverDidReceiveUserAttentionForUpdate:",
                 "standardUserDriverWillFinishUpdateSession",
                 "standardUserDriverWillShowReleaseNotesText:forUpdate:withBundleDisplayVersion:bundleVersion:"] {
        #expect(production.responds(to: NSSelectorFromString(name)))
    }
    var markdownProperties: [String: Any] = [
        "title": "Bend 0.4.0",
        "sparkle:version": "12002",
        "sparkle:shortVersionString": "0.4.0",
        "description": [
            "format": "markdown",
            "content": "## v0.4.0\n\n- Use `bend` with [docs](https://example.com/docs), [bad](javascript:alert(1)), [internal](bend-pane://id).",
        ],
        "enclosure": ["url": "https://example.invalid/Bend.dmg", "length": "100"],
    ]
    let markdownItem = try #require(SUAppcastItem(dictionary: markdownProperties))
    let rendered = try #require(production.standardUserDriverWillShowReleaseNotesText(
        NSAttributedString(string: "fallback"),
        forUpdate: markdownItem,
        withBundleDisplayVersion: "0.4.0",
        bundleVersion: "12002"
    ))
    let text = rendered.string as NSString
    #expect(text.contains("## v0.4.0") == false)
    #expect(text.contains("v0.4.0"))
    let codeLocation = try requiredLocation(of: "bend", in: text)
    let codeFont = try #require(rendered.attribute(.font, at: codeLocation, effectiveRange: nil) as? NSFont)
    #expect(codeFont.isFixedPitch)
    #expect(rendered.attribute(.backgroundColor, at: codeLocation, effectiveRange: nil) != nil)
    let docsLocation = try requiredLocation(of: "docs", in: text)
    #expect(rendered.attribute(.link, at: docsLocation, effectiveRange: nil) as? URL == URL(string: "https://example.com/docs"))
    let badLocation = try requiredLocation(of: "bad", in: text)
    #expect(rendered.attribute(.link, at: badLocation, effectiveRange: nil) == nil)
    let internalLocation = try requiredLocation(of: "internal", in: text)
    #expect(rendered.attribute(.link, at: internalLocation, effectiveRange: nil) == nil)

    markdownProperties["sparkle:releaseNotesLink"] = ["content": "https://example.com/full-notes.md"]
    let linkedItem = try #require(SUAppcastItem(dictionary: markdownProperties))
    try #require(linkedItem.releaseNotesURL != nil)
    #expect(AppUpdater.releaseNotesText(for: linkedItem) == nil)

    let htmlItem = try #require(SUAppcastItem(dictionary: [
        "title": "Bend 0.4.0",
        "sparkle:version": "12002",
        "sparkle:shortVersionString": "0.4.0",
        "description": "<pre>Legacy HTML</pre>",
        "enclosure": ["url": "https://example.invalid/Bend.dmg", "length": "100"],
    ]))
    #expect(production.standardUserDriverWillShowReleaseNotesText(
        NSAttributedString(string: "fallback"),
        forUpdate: htmlItem,
        withBundleDisplayVersion: "0.4.0",
        bundleVersion: "12002"
    ) == nil)
}

// @lat: [[lat.md/tests/updates-tests#Application update launch scheduling]]
@Test @MainActor func applicationUpdateLaunchScheduling() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(AppUpdater.needsLaunchCheck(lastCheck: nil, now: now))
    #expect(!AppUpdater.needsLaunchCheck(lastCheck: now, now: now))
    #expect(!AppUpdater.needsLaunchCheck(lastCheck: now.addingTimeInterval(-599), now: now))
    #expect(AppUpdater.needsLaunchCheck(lastCheck: now.addingTimeInterval(-600), now: now))
    #expect(AppUpdater.needsLaunchCheck(lastCheck: now.addingTimeInterval(-3600), now: now))
    // A clock correction must not suppress checks until a future timestamp.
    #expect(AppUpdater.needsLaunchCheck(lastCheck: now.addingTimeInterval(60), now: now))
}

#if !BEND_PRODUCTION
// @lat: [[lat.md/tests/updates-tests#Application update preview]]
@Test @MainActor func applicationUpdatePreview() async throws {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("BendUpdatePreview-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("Bend.app")
    try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    let info: [String: Any] = ["CFBundleIdentifier": "dev.yury.browse.preview-test",
        "CFBundleName": "Bend Preview Test", "CFBundleVersion": "1", "CFBundleShortVersionString": "0.2.0",
        "CFBundlePackageType": "APPL", "BendPreviewUpdates": true]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: app.appendingPathComponent("Contents/Info.plist"))
    let bundle = try #require(Bundle(url: app))
    let updater = AppUpdater(profile: .debug, bundle: bundle)
    updater.start()
    #expect(updater.availableVersion == "0.3.0")
    #expect(!updater.isEnabled)
    #expect(!updater.canCheckForUpdates)
    let production = AppUpdater(profile: .production, bundle: bundle)
    production.start()
    #expect(production.availableVersion == nil)
    var finished = false
    let preview = AppUpdatePreview(bundle: bundle) { finished = true }
    defer { preview.dismiss() }
    let item = try #require(preview.makeItem())
    #expect(item.displayVersionString == "0.3.0")
    #expect(item.itemDescriptionFormat == "markdown")
    #expect(item.itemDescription?.contains("Nothing will be downloaded") == true)
    let state = try #require(try AppUpdatePreview.makeState())
    #expect(state.stage == .notDownloaded)
    #expect(state.userInitiated)
    func subviews<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { subviews(type, in: $0) }
    }
    func button(_ title: String) -> NSButton? {
        NSApp.windows.filter(\.isVisible).compactMap(\.contentView).flatMap { subviews(NSButton.self, in: $0) }.first { $0.title == title }
    }
    func releaseNotesView() -> NSTextView? {
        NSApp.windows.filter(\.isVisible).compactMap(\.contentView).flatMap { subviews(NSTextView.self, in: $0) }
            .first { $0.string.contains("Update preview") }
    }
    preview.show()
    try await Task.sleep(for: .milliseconds(250))
    let notesView = try #require(releaseNotesView())
    let notesText = notesView.attributedString()
    let notesString = notesText.string as NSString
    #expect(notesString.contains("v0.3.0"))
    #expect(notesString.contains("Update preview"))
    #expect(notesString.contains("AppUpdatePreview"))
    #expect(!notesString.contains("##"))
    let previewCodeLocation = try requiredLocation(of: "AppUpdatePreview", in: notesString)
    let previewCodeFont = try #require(notesText.attribute(.font, at: previewCodeLocation, effectiveRange: nil) as? NSFont)
    #expect(previewCodeFont.isFixedPitch)
    let previewLinkLocation = try requiredLocation(of: "release notes", in: notesString)
    #expect(notesText.attribute(.link, at: previewLinkLocation, effectiveRange: nil) as? URL == URL(string: "https://example.invalid/releases"))
    try #require(button("Install Update")).performClick(nil)
    try await Task.sleep(for: .milliseconds(250))
    try #require(button("Cancel")).performClick(nil)
    try await Task.sleep(for: .milliseconds(100))
    #expect(!finished)
    preview.show()
    try await Task.sleep(for: .milliseconds(250))
    try #require(button("Install Update")).performClick(nil)
    for _ in 0..<70 {
        if button("Install and Relaunch") != nil { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    try #require(button("Install and Relaunch")).performClick(nil)
    try await Task.sleep(for: .milliseconds(100))
    #expect(finished)
}
#endif
