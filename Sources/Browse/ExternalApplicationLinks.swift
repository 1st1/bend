import AppKit

// @lat: [[lat.md/architecture/external-links#External application links]]
@MainActor
final class ExternalApplicationLinks {
    struct Application {
        let url: URL
        let name: String
    }

    enum Prompt {
        case open(Application, source: URL?)
        case unavailable(scheme: String)
        case failed(Application)
    }

    static let shared = ExternalApplicationLinks()
    private var pendingWindows = Set<ObjectIdentifier>()
    private let resolve: @MainActor (URL) -> Application?
    private let confirm: @MainActor (Prompt, NSWindow) async -> Bool
    private let open: @MainActor (URL, Application) async throws -> Void

    init(resolve: @escaping @MainActor (URL) -> Application? = ExternalApplicationLinks.resolveApplication,
         confirm: @escaping @MainActor (Prompt, NSWindow) async -> Bool = ExternalApplicationLinks.present,
         open: @escaping @MainActor (URL, Application) async throws -> Void = { url, application in
             _ = try await NSWorkspace.shared.open([url], withApplicationAt: application.url,
                                                  configuration: NSWorkspace.OpenConfiguration())
         }) {
        self.resolve = resolve
        self.confirm = confirm
        self.open = open
    }

    static func isExternal(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return !["http", "https", "about", "file", "data", "javascript", "blob", "browse", "applewebdata", "webkit-extension", "safari-web-extension"].contains(scheme)
    }

    @discardableResult
    func request(_ url: URL, source: URL?, in window: NSWindow) -> Task<Void, Never>? {
        let windowID = ObjectIdentifier(window)
        guard Self.isExternal(url), window.isVisible, window.attachedSheet == nil,
              pendingWindows.insert(windowID).inserted else { return nil }
        // Reserve the window synchronously, before either WebKit callback can
        // enqueue a second request. Never queue launches behind another prompt.
        return Task { @MainActor in
            defer { pendingWindows.remove(windowID) }
            guard let application = resolve(url) else {
                _ = await confirm(.unavailable(scheme: url.scheme!.lowercased()), window)
                return
            }
            guard await confirm(.open(application, source: source), window), window.isVisible else { return }
            do {
                // Open with the exact app the user approved, not a newly resolved handler.
                try await open(url, application)
            } catch {
                if window.isVisible { _ = await confirm(.failed(application), window) }
            }
        }
    }

    private static func resolveApplication(_ url: URL) -> Application? {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(toOpen: url) else { return nil }
        if let ownID = Bundle.main.bundleIdentifier, Bundle(url: applicationURL)?.bundleIdentifier == ownID { return nil }
        let name = (FileManager.default.displayName(atPath: applicationURL.path) as NSString).deletingPathExtension
        return Application(url: applicationURL, name: name)
    }

    static func sourceName(_ url: URL?) -> String {
        guard let url else { return "This page" }
        if url.isFileURL { return "This local page" }
        guard let scheme = url.scheme, ["http", "https"].contains(scheme), let host = url.host else { return "This page" }
        return "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "")
    }

    private static func present(_ prompt: Prompt, in window: NSWindow) async -> Bool {
        let alert = NSAlert()
        switch prompt {
        case .open(let application, let source):
            alert.messageText = "Open in \(application.name)?"
            alert.informativeText = "\(sourceName(source)) wants to open this link in \(application.name)."
            alert.icon = NSWorkspace.shared.icon(forFile: application.url.path)
            alert.addButton(withTitle: "Open")
            alert.addButton(withTitle: "Cancel")
        case .unavailable(let scheme):
            alert.messageText = "No app can open this link"
            alert.informativeText = "Install an app that handles \(scheme) links, then try again."
            alert.addButton(withTitle: "OK")
        case .failed(let application):
            alert.messageText = "Couldn’t open \(application.name)"
            alert.informativeText = "The app couldn’t open this link. Try opening the app and clicking the link again."
            alert.addButton(withTitle: "OK")
        }
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
    }
}
