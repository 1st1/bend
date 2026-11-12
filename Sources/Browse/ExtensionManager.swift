import AppKit
import Combine
import CryptoKit
import WebKit
import Security

struct ExtensionRecord: Codable, Identifiable {
    var id: UUID
    var source: URL
    var isBundle: Bool
    var name: String
    var enabled = false
    var enabledInPrivateMode: Bool?
    var permissions: [String] = []
    var websites: [String] = []
    var importedFrom: URL?
    var packageIdentifier: String?
    // Set only by the verified catalog download path, never inferred from a name.
    var catalogID: String?
}

// @lat: [[architecture#Web extensions]]
@available(macOS 15.4, *)
@MainActor
final class ExtensionManager: NSObject, ObservableObject {
    @Published private(set) var records: [ExtensionRecord] = []
    @Published private(set) var busy = false
    @Published private(set) var catalogInstallingID: String?
    private var catalogTask: Task<Void, Never>?
    lazy var updates = ExtensionUpdater(manager: self)
    @Published var error: String?
    @Published private(set) var failures: [UUID: String] = [:]
    let controller: WKWebExtensionController
    let compatibility: ExtensionCompatibility
    let nativeMessaging = ExtensionNativeMessaging()
    let diagnostics: ExtensionDiagnostics
    var diagnosticErrors: [UUID: Set<String>] = [:]
    let root: URL
    weak var store: BrowserStore?
    weak var browserWindow: NSWindow?
    private(set) var contexts: [UUID: WKWebExtensionContext] = [:]
    var tabs: [UUID: ExtensionTab] = [:]
    lazy var window = ExtensionWindow(manager: self)
    var browserWindows: [ExtensionWindow] = []
    var hasRegisteredWindows = false
    var activeID: UUID?
    var activePanes: [ObjectIdentifier: UUID] = [:]
    private var started = false
    private(set) var restorationTask: Task<Void, Never>?
    private var writable = true
    var documents: [UUID: ExtensionDocument] = [:]
    private var errorObservation: AnyCancellable?
    var popupPaneID: UUID?
    var popup: NSPopover? {
        didSet {
            if let oldValue { NotificationCenter.default.removeObserver(self, name: NSPopover.didCloseNotification, object: oldValue) }
            if let popup {
                NotificationCenter.default.addObserver(self, selector: #selector(tracePopupClosed(_:)),
                    name: NSPopover.didCloseNotification, object: popup)
            }
        }
    }
    @objc private func tracePopupClosed(_ notification: Notification) {
        InputDiagnostics.transition(.extensionPopup, .hidden, paneID: popupPaneID)
    }
    var presentsWindows = true

    init(root: URL, persistent: Bool = true, storageIdentifier: UUID? = nil,
         websiteDataStore: WKWebsiteDataStore? = nil, notifications: (any ExtensionNotificationDelivering)? = nil) {
        self.root = root
        diagnostics = ExtensionDiagnostics(root: root)
        compatibility = ExtensionCompatibility(notifications: notifications ?? ExtensionNotifications())
        let websiteDataStore = websiteDataStore ?? (persistent ? AppProfile.current.websiteDataStore : nil)
        let storageIdentifier = storageIdentifier ?? AppProfile.current.extensionStorageIdentifier
        let configuration: WKWebExtensionController.Configuration
        if !persistent { configuration = .nonPersistent() }
        else if let storageIdentifier { configuration = .init(identifier: storageIdentifier) }
        else { configuration = .default() }
        if let websiteDataStore { configuration.defaultWebsiteDataStore = websiteDataStore }
        let webConfiguration = configuration.webViewConfiguration ?? WKWebViewConfiguration()
        if let websiteDataStore { webConfiguration.websiteDataStore = websiteDataStore }
        compatibility.configure(webConfiguration)
        configuration.webViewConfiguration = webConfiguration
        controller = WKWebExtensionController(configuration: configuration)
        super.init()
        compatibility.manager = self
        nativeMessaging.manager = self
        diagnostics.changed = { [weak self] in self?.objectWillChange.send() }
        diagnostics.record(.hostStarted, fields: [
            "extensionStoragePersistent": String(persistent), "extensionStore": storageIdentifier?.uuidString ?? "default",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "executableModified": Bundle.main.executableURL.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown"
        ])
        diagnostics.record(.signingPreflight, fields: OnePasswordSigningStatus.current.fields)
        controller.delegate = self
        errorObservation = NotificationCenter.default.publisher(for: WKWebExtensionContext.errorsDidUpdateNotification)
            .receive(on: RunLoop.main).sink { [weak self] notification in
                if let context = notification.object as? WKWebExtensionContext { self?.logRuntimeErrors(context) }
                self?.objectWillChange.send()
            }
        let file = root.appendingPathComponent("extensions.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                records = try JSONDecoder().decode([ExtensionRecord].self, from: Data(contentsOf: file))
                guard Set(records.map(\.id)).count == records.count, records.allSatisfy({ $0.source.isFileURL }) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            } catch {
                diagnostics.record(.metadataReadFailed, fields: ExtensionDiagnostics.errorFields(error))
                records = []; writable = false
                self.error = "Saved extensions could not be read. The original file has been preserved."
            }
        }
    }

    func start() {
        guard !started else { return }
        started = true
        diagnostics.record(.restoreStarted, fields: ["records": String(records.count)])
        synchronizeTabs()
        controller.didOpenWindow(window)
        controller.didFocusWindow(window)
        guard !records.isEmpty else { diagnostics.record(.restoreFinished); return }
        busy = true
        restorationTask = Task {
            for saved in records {
                do {
                    var record = saved
                    if !ownsPackage(record) {
                        let copy = try await copyPackage(from: record.source, id: record.id)
                        do {
                            record.importedFrom = record.source
                            record.source = copy
                            let context = try await makeContext(record)
                            record.packageIdentifier = packageIdentifier(record, extension: context.webExtension)
                            var next = records
                            next[next.firstIndex(where: { $0.id == record.id })!] = record
                            try persist(next)
                        } catch { discardPackage(copy, id: record.id); throw error }
                    }
                    let context = try await makeContext(record)
                    contexts[record.id] = context
                    if record.enabled {
                        // Updates may request more access; never silently grant it.
                        if !missingPermissions(context).isEmpty {
                            failures[record.id] = "New permissions are required. Turn the extension on to review them."
                        } else { try controller.load(context) }
                    }
                    logSnapshot(.extensionRestored, context: context)
                } catch {
                    failures[saved.id] = error.localizedDescription
                    diagnostics.record(.extensionLoadFailed, extensionID: saved.id, fields: ExtensionDiagnostics.errorFields(error))
                }
            }
            diagnostics.record(.restoreFinished, fields: ["loaded": String(contexts.values.filter(\.isLoaded).count)])
            busy = false
        }
    }

    func configure(_ configuration: WKWebViewConfiguration) {
        configuration.webExtensionController = controller
        if let dataStore = controller.configuration.defaultWebsiteDataStore { configuration.websiteDataStore = dataStore }
    }

    private func makeContext(_ record: ExtensionRecord) async throws -> WKWebExtensionContext {
        let webExtension: WKWebExtension
        if record.isBundle {
            guard let bundle = Bundle(url: record.source) else { throw CocoaError(.fileReadCorruptFile) }
            webExtension = try await WKWebExtension(appExtensionBundle: bundle)
        } else { webExtension = try await WKWebExtension(resourceBaseURL: record.source) }
        let context = WKWebExtensionContext(for: webExtension)
        context.hasAccessToPrivateData = record.enabledInPrivateMode ?? false
        context.uniqueIdentifier = record.id.uuidString
        let identity = packageIdentifier(record, extension: webExtension)
        let scheme = Self.usesSafariOrigin(identity) ? "safari-web-extension" : "webkit-extension"
        if scheme == "safari-web-extension" {
            WKWebExtension.MatchPattern.registerCustomURLScheme(scheme)
        }
        context.baseURL = URL(string: "\(scheme)://\(record.id.uuidString.lowercased())/")!
        context.unsupportedAPIs = ["browser.windows.create", "browser.tabs.move", "browser.tabs.group", "browser.tabs.ungroup"]
        for permission in record.permissions {
            context.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.Permission(rawValue: permission))
        }
        for website in record.websites {
            if let pattern = try? WKWebExtension.MatchPattern(string: website) {
                context.setPermissionStatus(.grantedExplicitly, for: pattern)
            }
        }
        return context
    }

    // uBlock Lite selects WebKit workarounds from runtime.getURL's scheme.
    // Keep its UUID (and browser.storage namespace) stable across this change.
    static func usesSafariOrigin(_ identity: String?) -> Bool {
        identity == "safari:net.raymondhill.uBlock-Origin-Lite.Extension"
    }

    func restoredExtensionURL(_ url: URL) -> URL {
        guard url.scheme == "webkit-extension",
              let context = contexts.values.first(where: {
                  $0.baseURL.scheme == "safari-web-extension" && $0.baseURL.host == url.host
              }), var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.scheme = context.baseURL.scheme
        return components.url ?? url
    }

    static func webExtensionBundles(in app: URL) -> [URL] {
        let directory = app.appendingPathComponent("Contents/PlugIns")
        return ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []).filter {
            guard $0.pathExtension == "appex", let bundle = Bundle(url: $0),
                  let extensionInfo = bundle.infoDictionary?["NSExtension"] as? [String: Any] else { return false }
            return extensionInfo["NSExtensionPointIdentifier"] as? String == "com.apple.Safari.web-extension"
        }
    }

    func chooseExtension() {
        let panel = NSOpenPanel()
        panel.title = "Install Extension in Bend"
        panel.message = "Choose a downloaded ZIP, XPI, or CRX package, an extension folder, or a Safari extension app. Bend installs its own copy."
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        add(url)
    }

    func add(_ source: URL) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let sources = source.pathExtension == "app" ? Self.webExtensionBundles(in: source) : [source]
                guard !sources.isEmpty else {
                    throw failure("This app does not contain a Safari Web Extension. Native Safari App Extensions cannot run in Bend.")
                }
                for url in sources { try await importExtension(from: url) }
            } catch { self.error = error.localizedDescription }
        }
    }

    func catalogRecord(_ entry: CatalogExtension) -> ExtensionRecord? {
        records.first { $0.packageIdentifier == entry.packageIdentifier }
    }

    func installFromCatalog(_ entry: CatalogExtension) {
        guard !busy, catalogRecord(entry) == nil else { return }
        busy = true; catalogInstallingID = entry.id; error = nil
        catalogTask = Task {
            defer { busy = false; catalogInstallingID = nil; catalogTask = nil }
            do {
                let download = entry.download
                let data = try await download.fetch()
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BrowseCatalog-\(UUID())")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let package = directory.appendingPathComponent("package.\(download.url.pathExtension)")
                try await Task.detached(priority: .utility) { try data.write(to: package, options: .atomic) }.value
                try Task.checkCancellation()
                try await importExtension(from: package, expectedIdentifier: entry.packageIdentifier,
                    catalogID: entry.id, expectedVersion: download.version)
            } catch is CancellationError {
                // Cancelling a download leaves the installed list unchanged.
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    func cancelCatalogInstall() { catalogTask?.cancel() }

    func importExtension(from source: URL, expectedIdentifier: String? = nil,
                         catalogID: String? = nil, expectedVersion: String? = nil) async throws {
        guard writable else { throw failure("The saved extension list is unreadable.") }
        guard !records.contains(where: { ($0.importedFrom ?? $0.source) == source }) else {
            throw failure("This package is already installed.")
        }
        var record = ExtensionRecord(id: UUID(), source: source, isBundle: source.pathExtension == "appex", name: source.lastPathComponent)
        record.catalogID = catalogID
        record.importedFrom = source
        record.source = try await copyPackage(from: source, id: record.id)
        do {
            let context = try await makeContext(record)
            if let expectedVersion, context.webExtension.version != expectedVersion {
                throw failure("The downloaded extension has an unexpected version.")
            }
            record.packageIdentifier = packageIdentifier(record, extension: context.webExtension)
            if let expectedIdentifier, record.packageIdentifier != expectedIdentifier {
                throw failure("This package does not match the catalog entry. Nothing was installed.")
            }
            try Task.checkCancellation()
            if let identity = record.packageIdentifier, records.contains(where: { $0.packageIdentifier == identity }) {
                throw failure("This extension is already installed.")
            }
            record.name = context.webExtension.displayName ?? record.name
            try persist(records + [record])
            contexts[record.id] = context
            diagnostics.record(.extensionImported, extensionID: record.id)
        } catch {
            discardPackage(record.source, id: record.id)
            throw error
        }
    }

    func ownsPackage(_ record: ExtensionRecord) -> Bool {
        record.source.standardizedFileURL.path.hasPrefix(root.appendingPathComponent(record.id.uuidString).standardizedFileURL.path + "/")
    }

    private func copyPackage(from source: URL, id: UUID) async throws -> URL {
        let root = root
        return try await Task.detached(priority: .utility) {
            try Self.copyPackage(from: source, id: id, root: root)
        }.value
    }

    nonisolated private static func copyPackage(from source: URL, id: UUID, root: URL) throws -> URL {
        func failure(_ message: String) -> NSError {
            NSError(domain: "Browse.Extensions", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        guard source.isFileURL else { throw failure("Choose a downloaded extension package.") }
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]
        func validate(_ url: URL, within package: URL) throws {
            let values = try url.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true {
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
                let resolved = url.resolvingSymlinksInPath().standardizedFileURL
                let base = package.resolvingSymlinksInPath().standardizedFileURL.path
                guard url != package, !target.hasPrefix("/"), resolved.path.hasPrefix(base + "/") else {
                    throw failure("Extension links must stay inside the installed package.")
                }
                let resolvedValues = try resolved.resourceValues(forKeys: keys)
                guard resolvedValues.isSymbolicLink != true,
                      resolvedValues.isDirectory == true || resolvedValues.isRegularFile == true else {
                    throw failure("The extension contains an invalid symbolic link.")
                }
            } else if values.isDirectory != true && values.isRegularFile != true {
                throw failure("Extension packages cannot contain special files.")
            }
        }
        let sourcePath = source.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard rootPath != sourcePath, !rootPath.hasPrefix(sourcePath + "/") else {
            throw failure("Choose an extension package, not a folder containing Bend’s extension storage.")
        }
        func validateTree(_ source: URL) throws {
            try validate(source, within: source)
            guard try source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { return }
            var enumerationError: Error?
            let files = FileManager.default.enumerator(at: source, includingPropertiesForKeys: Array(keys), errorHandler: { _, error in
                enumerationError = error; return false
            })
            while let file = files?.nextObject() as? URL { try validate(file, within: source) }
            if let enumerationError { throw enumerationError }
        }
        try validateTree(source)
        let revision = root.appendingPathComponent(id.uuidString).appendingPathComponent(UUID().uuidString)
        let copy = revision.appendingPathComponent(source.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: revision, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: copy)
            try validateTree(copy)
            return copy
        } catch { try? FileManager.default.removeItem(at: revision); throw error }
    }

    private func discardPackage(_ source: URL, id: UUID) {
        let directory = root.appendingPathComponent(id.uuidString).standardizedFileURL
        guard source.standardizedFileURL.path.hasPrefix(directory.path + "/") else { return }
        try? FileManager.default.removeItem(at: source)
        let parent = source.deletingLastPathComponent()
        if (try? FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty) == true {
            try? FileManager.default.removeItem(at: parent)
        }
    }

    private func packageIdentifier(_ record: ExtensionRecord, extension webExtension: WKWebExtension) -> String? {
        if record.isBundle { return Bundle(url: record.source)?.bundleIdentifier.map { "safari:" + $0 } }
        let manifest = webExtension.manifest
        if record.catalogID == "ublock-lite",
           let settings = manifest["browser_specific_settings"] as? [String: Any],
           settings["safari"] != nil, settings["gecko"] == nil {
            return "safari:net.raymondhill.uBlock-Origin-Lite.Extension"
        }
        for key in ["browser_specific_settings", "applications"] {
            if let settings = manifest[key] as? [String: Any], let gecko = settings["gecko"] as? [String: Any], let id = gecko["id"] as? String {
                return "gecko:" + id
            }
        }
        if let key = manifest["key"] as? String, let data = Data(base64Encoded: key) {
            return "key:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return nil
    }

    func replacePackage(_ id: UUID, from input: URL, catalogID: String? = nil,
                        expectedVersion: String? = nil) async throws {
        guard writable, let index = records.firstIndex(where: { $0.id == id }) else { throw failure("The extension cannot be updated.") }
        let old = records[index]
        let oldContext: WKWebExtensionContext
        if let existing = contexts[id] { oldContext = existing }
        else { oldContext = try await makeContext(old) }
        let oldIdentity = old.packageIdentifier ?? packageIdentifier(old, extension: oldContext.webExtension)
        let source: URL
        if input.pathExtension == "app" {
            guard let bundle = Self.webExtensionBundles(in: input).first(where: {
                Bundle(url: $0)?.bundleIdentifier.map { "safari:" + $0 } == oldIdentity
            }) else { throw failure("This app does not contain the installed extension.") }
            source = bundle
        } else { source = input }
        var replacement = old
        replacement.catalogID = catalogID
        replacement.source = try await copyPackage(from: source, id: id)
        replacement.importedFrom = source
        replacement.isBundle = source.pathExtension == "appex"
        var committed = false
        defer { if !committed { discardPackage(replacement.source, id: id) } }
        let context = try await makeContext(replacement)
        if let expectedVersion, context.webExtension.version != expectedVersion {
            throw failure("The downloaded extension has an unexpected version.")
        }
        try Task.checkCancellation()
        let newIdentity = packageIdentifier(replacement, extension: context.webExtension)
        guard oldIdentity == newIdentity,
              oldIdentity != nil || oldContext.webExtension.displayName == context.webExtension.displayName else {
            throw failure("This package belongs to a different extension.")
        }
        replacement.packageIdentifier = newIdentity
        replacement.name = context.webExtension.displayName ?? old.name
        let needsApproval = !missingPermissions(context).isEmpty
        let wasLoaded = oldContext.isLoaded
        do {
            if wasLoaded { try controller.unload(oldContext) }
            if old.enabled && !needsApproval { try controller.load(context) }
            var next = records; next[index] = replacement
            try persist(next)
        } catch {
            if context.isLoaded { try? controller.unload(context) }
            if wasLoaded { try? controller.load(oldContext) }
            throw error
        }
        committed = true
        closeDocuments(for: oldContext); popup?.close()
        contexts[id] = context
        logSnapshot(.extensionUpdated, context: context)
        failures[id] = old.enabled && needsApproval ? "The update needs additional permissions. Turn the extension on to review them." : nil
        discardPackage(old.source, id: id)
    }

    // The download runs outside the mutation lock; recheck the revision before swapping.
    func applyCatalogUpdate(_ id: UUID, from input: URL, entry: CatalogExtension,
                            version: String, replacing source: URL) async throws {
        guard !busy, let record = records.first(where: { $0.id == id }),
              record.source == source, record.packageIdentifier == entry.packageIdentifier else {
            throw failure("The extension changed during the update. Check again to retry.")
        }
        busy = true
        defer { busy = false }
        try await replacePackage(id, from: input, catalogID: entry.id, expectedVersion: version)
    }

    private func persist(_ next: [ExtensionRecord]) throws {
        guard writable else { throw failure("The saved extension list is unreadable.") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: root.appendingPathComponent("extensions.json"), options: .atomic)
        records = next
    }

    func isEnabled(_ id: UUID) -> Bool { contexts[id]?.isLoaded == true }

    func isAvailable(_ id: UUID, pageID: UUID) -> Bool {
        guard let context = contexts[id], context.isLoaded, let owner = store(for: pageID) else { return false }
        return !owner.isPrivate || context.hasAccessToPrivateData
    }

    func setPrivateAccess(_ enabled: Bool, id: UUID) {
        guard !busy, let index = records.firstIndex(where: { $0.id == id }) else { return }
        var next = records
        next[index].enabledInPrivateMode = enabled
        do {
            try persist(next)
            guard let context = contexts[id] else { return }
            context.hasAccessToPrivateData = enabled
            if enabled, context.isLoaded {
                // Windows omitted during initial loading must be registered with
                // this context only after the user explicitly permits access.
                for window in browserWindows where window.owningStore?.isPrivate == true {
                    if !context.openWindows.contains(where: { $0 === window }) { context.didOpenWindow(window) }
                    for tab in window.tabs(for: context) where !context.openTabs.contains(where: { ($0.base as? ExtensionTab) === tab }) {
                        context.didOpenTab(tab)
                    }
                }
            }
            if !enabled {
                popup?.close()
                for owner in browserStores where owner.isPrivate {
                    for page in owner.session.workspaces.flatMap(\.tabs).flatMap(\.pages) {
                        owner.existingController(for: page.id)?.unloadExtension(at: context.baseURL)
                    }
                }
            }
        } catch { self.error = error.localizedDescription }
    }

    func compatibilityNotice(_ id: UUID) -> String? {
        guard let record = records.first(where: { $0.id == id }) else { return nil }
        if record.packageIdentifier == "gecko:{e839c3f9-298e-4cd0-99e0-464431cb7c34}" {
            return "Foxy’s default right-button gestures require context menus on mouse release, which Bend’s WebKit engine does not support. Choose a different gesture button in Foxy’s settings. Some Firefox-specific commands are unavailable."
        }
        if record.packageIdentifier == "gecko:{d634138d-c276-4fc8-924b-40a0ea21d284}" {
            let signing = OnePasswordSigningStatus.current
            if signing.certificateStatus != errSecSuccess {
                return "This build’s certificate does not meet 1Password’s desktop-integration signing requirement. Sign Bend with a Developer ID Application certificate; reinstalling the extension will not fix this. Standalone sign-in remains available."
            }
            if !signing.hardenedRuntime { return "1Password desktop integration requires Bend to be signed with Hardened Runtime enabled." }
            return nil
        }
        if record.isBundle, Bundle(url: record.source)?.bundleIdentifier == "com.1password.safari.extension" {
            return "1Password for Safari is not supported in Bend yet. Its native app connection fails, so enabling it does not mean unlocking or autofill will work."
        }
        return nil
    }

    func permissionSummary(_ id: UUID) -> [String] {
        guard let context = contexts[id] else { return [] }
        let ext = context.webExtension
        return ExtensionCompatibility.requiredPermissions(for: ext).map(\.rawValue).sorted()
            + ext.allRequestedMatchPatterns.union(ext.requestedPermissionMatchPatterns).map(\.string).sorted()
    }

    private func missingPermissions(_ context: WKWebExtensionContext) -> [String] {
        let ext = context.webExtension
        return ExtensionCompatibility.requiredPermissions(for: ext).filter { !ExtensionCompatibility.hasPermission($0, in: context) }.map(\.rawValue)
            + ext.allRequestedMatchPatterns.union(ext.requestedPermissionMatchPatterns)
                .filter { context.permissionStatus(for: $0).rawValue < WKWebExtensionContext.PermissionStatus.grantedImplicitly.rawValue }.map(\.string)
    }

    func setEnabled(_ enabled: Bool, id: UUID) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do { try await enable(enabled, id: id) { [weak self] name, permissions in self?.approve(name, details: permissions) == true } }
            catch { self.error = error.localizedDescription }
        }
    }

    func enable(_ enabled: Bool, id: UUID, approve: (String, [String]) -> Bool) async throws {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        let context: WKWebExtensionContext
        if let existing = contexts[id] { context = existing }
        else { context = try await makeContext(records[index]); contexts[id] = context }
        var next = records
        if enabled {
            let missing = missingPermissions(context)
            guard missing.isEmpty || approve(records[index].name, missing.sorted()) else { return }
            let ext = context.webExtension
            let permissions = ExtensionCompatibility.requiredPermissions(for: ext)
            next[index].permissions = Array(Set(next[index].permissions).union(permissions.map(\.rawValue))).sorted()
            next[index].websites = Array(Set(next[index].websites).union(ext.allRequestedMatchPatterns.union(ext.requestedPermissionMatchPatterns).map(\.string))).sorted()
            for permission in permissions { context.setPermissionStatus(.grantedExplicitly, for: permission) }
            for pattern in ext.allRequestedMatchPatterns.union(ext.requestedPermissionMatchPatterns) {
                context.setPermissionStatus(.grantedExplicitly, for: pattern)
            }
            if !context.isLoaded { try controller.load(context) }
        } else {
            if context.isLoaded { try controller.unload(context) }
            closeDocuments(for: context)
            popup?.close()
        }
        next[index].enabled = enabled
        do { try persist(next) }
        catch {
            if enabled, context.isLoaded { try? controller.unload(context) }
            throw error
        }
        failures[id] = nil
        logSnapshot(enabled ? .extensionLoaded : .extensionDisabled, context: context)
    }

    func remove(_ id: UUID) {
        guard !busy, let record = records.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Remove \(record.name) from Bend?"
        alert.informativeText = "Its Bend extension data will be deleted. The installed app and Safari settings are kept."
        alert.addButton(withTitle: "Remove"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        busy = true
        Task {
            defer { busy = false }
            do { try await uninstall(id) } catch { self.error = error.localizedDescription }
        }
    }

    func uninstall(_ id: UUID) async throws {
        guard writable, records.contains(where: { $0.id == id }) else { throw failure("The extension cannot be removed.") }
        if let context = contexts[id] {
            closeDocuments(for: context)
            let data = await controller.dataRecord(ofTypes: WKWebExtensionController.allExtensionDataTypes, for: context)
            if context.isLoaded { try controller.unload(context) }
            if let data { await controller.removeData(ofTypes: WKWebExtensionController.allExtensionDataTypes, from: [data]) }
        }
        diagnostics.record(.extensionRemoved, extensionID: id)
        try persist(records.filter { $0.id != id })
        contexts[id] = nil; failures[id] = nil
        try? FileManager.default.removeItem(at: root.appendingPathComponent(id.uuidString))
    }

    func approve(_ name: String, details: [String]) -> Bool {
        InputDiagnostics.transition(.extensionPermission, .shown, window: browserWindow, paneID: activeID)
        defer { InputDiagnostics.transition(.extensionPermission, .hidden, window: browserWindow, paneID: activeID) }
        let alert = NSAlert()
        alert.messageText = "Allow \(name) access in Bend?"
        alert.informativeText = details.joined(separator: "\n")
        alert.addButton(withTitle: "Allow"); alert.addButton(withTitle: "Don’t Allow")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func settingsPageURL(_ id: UUID) -> URL? {
        guard let context = contexts[id] else { return nil }
        if let url = context.optionsPageURL { return url }
        guard let record = records.first(where: { $0.id == id }),
              let page = CatalogExtension.curated.first(where: { $0.packageIdentifier == record.packageIdentifier })?.settingsPage else {
            return nil
        }
        return URL(string: page, relativeTo: context.baseURL)?.absoluteURL
    }

    func showOptions(_ id: UUID) {
        guard let context = contexts[id] else { return }
        do { try showOptions(context) } catch { self.error = error.localizedDescription }
    }

    func showOptions(_ context: WKWebExtensionContext) throws {
        guard context.isLoaded else {
            throw failure("Enable the extension before opening its settings.")
        }
        guard let id = contexts.first(where: { $0.value === context })?.key,
              let url = settingsPageURL(id) else {
            throw failure("This extension does not provide a settings page.")
        }
        if let existing = documents.values.first(where: { $0.context === context && $0.web.url == url }) {
            if presentsWindows { existing.nativeWindow.makeKeyAndOrderFront(nil) }
            return
        }
        _ = try openDocument(url: url, context: context)
    }

    func openDocument(url: URL, context: WKWebExtensionContext, active: Bool = true) throws -> ExtensionDocument {
        guard let config = context.webViewConfiguration,
              url.scheme == context.baseURL.scheme, url.host == context.baseURL.host else {
            throw failure("The extension page is unavailable.")
        }
        let document = ExtensionDocument(manager: self, context: context, configuration: config)
        documents[document.id] = document
        controller.didOpenWindow(document)
        controller.didOpenTab(document)
        document.navigate(to: url)
        if presentsWindows {
            document.nativeWindow.center()
            if active { document.nativeWindow.makeKeyAndOrderFront(nil) }
            else { document.nativeWindow.orderBack(nil) }
        }
        return document
    }

    func closeDocuments(for context: WKWebExtensionContext) {
        nativeMessaging.stop(context)
        if let id = UUID(uuidString: context.uniqueIdentifier) { compatibility.stop(id) }
        for document in Array(documents.values) where document.context === context { document.nativeWindow.close() }
        for page in pages { store(for: page.id)?.existingController(for: page.id)?.unloadExtension(at: context.baseURL) }
    }

    func performAction(_ id: UUID, pageID: UUID) {
        guard isAvailable(id, pageID: pageID), let context = contexts[id], let tab = tabs[pageID] else { return }
        if tab.store?.isPrivate == true, context.action(for: tab)?.presentsPopup == true {
            tab.pageController?.error = "Extension popups are unavailable in private windows because their website storage cannot be isolated."
            return
        }
        store(for: pageID)?.revealPage(pageID)
        context.userGesturePerformed(in: tab)
        context.performAction(for: tab)
    }

    func failure(_ message: String) -> NSError {
        NSError(domain: "Browse.Extensions", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
