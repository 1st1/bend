#if !BEND_PRODUCTION
import AppKit
import Sparkle

// @lat: [[lat.md/architecture/updates#Update interface preview]]
@MainActor
final class AppUpdatePreview {
    let version = "0.3.0"
    private let bundle: Bundle
    private let completion: () -> Void
    private var driver: SPUStandardUserDriver?
    private var progress: Task<Void, Never>?

    init(bundle: Bundle, completion: (() -> Void)? = nil) {
        self.bundle = bundle
        self.completion = completion ?? Self.showCompletion
    }

    func show() {
        if let driver { driver.showUpdateInFocus(); return }
        guard let item = makeItem(), let state = try? Self.makeState() else { return }
        let driver = SPUStandardUserDriver(hostBundle: bundle, delegate: nil)
        self.driver = driver
        driver.showUpdateFound(with: item, state: state) { [weak self] choice in
            // Let Sparkle finish closing its release-notes window first.
            Task { @MainActor in
                guard let self else { return }
                if choice == .install { self.simulateDownload() } else { self.dismiss() }
            }
        }
    }

    func makeItem() -> SUAppcastItem? {
        // Sparkle's dictionary initializer is sufficient for this display-only fixture;
        // no version selection, network request, updater, or installer is involved.
        SUAppcastItem(dictionary: [
            "title": "Bend \(version)",
            "sparkle:version": "999999999",
            "sparkle:shortVersionString": version,
            "description": """
                <h2>Update preview</h2>
                <p>This is a demonstration of Bend’s update experience.</p>
                <ul><li>See the download and preparation progress.</li>
                <li>Try the Install and Relaunch button.</li></ul>
                <p>Nothing will be downloaded or installed, and Bend will stay open.</p>
                """,
            "enclosure": ["url": "https://example.invalid/Bend-preview.dmg", "length": "24000000"],
        ])
    }

    static func makeState() throws -> SPUUserUpdateState? {
        // The pinned Sparkle 2.10.1 exposes NSSecureCoding but no public state
        // initializer. Decode a local fixture using that version's archive keys.
        let archive = NSKeyedArchiver(requiringSecureCoding: true)
        archive.encode(SPUUserUpdateStage.notDownloaded.rawValue, forKey: "SPUUserUpdateStateStage")
        archive.encode(true, forKey: "SPUUserUpdateStateUserInitiated")
        archive.finishEncoding()
        let decoder = try NSKeyedUnarchiver(forReadingFrom: archive.encodedData)
        defer { decoder.finishDecoding() }
        return SPUUserUpdateState(coder: decoder)
    }

    private func simulateDownload() {
        guard let driver else { return }
        driver.showDownloadInitiated { [weak self] in self?.dismiss() }
        driver.showDownloadDidReceiveExpectedContentLength(24_000_000)
        progress = Task { @MainActor [weak self] in
            do {
                for _ in 0..<24 {
                    try await Task.sleep(for: .milliseconds(125))
                    driver.showDownloadDidReceiveData(ofLength: 1_000_000)
                }
                driver.showDownloadDidStartExtractingUpdate()
                for step in 1...10 {
                    try await Task.sleep(for: .milliseconds(100))
                    driver.showExtractionReceivedProgress(Double(step) / 10)
                }
                let choice = await driver.showReadyToInstallAndRelaunch()
                guard !Task.isCancelled else { return }
                self?.dismiss()
                guard choice == .install else { return }
                self?.completion()
            } catch { /* Cancelling the preview stops simulated progress. */ }
        }
    }

    private static func showCompletion() {
        let alert = NSAlert()
        alert.messageText = "Update preview complete"
        alert.informativeText = "A real update would now quit Bend, install the verified release, and reopen your browser. This preview has left your app unchanged."
        alert.addButton(withTitle: "Done")
        if let window = NSApp.mainWindow { alert.beginSheetModal(for: window, completionHandler: nil) }
        else { alert.runModal() }
    }

    func dismiss() {
        progress?.cancel()
        progress = nil
        driver?.dismissUpdateInstallation()
        driver = nil
    }
}
#endif
