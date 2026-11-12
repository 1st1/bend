import AppKit
import WebKit

// @lat: [[lat.md/architecture/web-pages#JavaScript dialogs]]
@MainActor
final class JavaScriptDialogs {
    enum Kind { case alert, confirm, prompt }
    struct Request {
        let kind: Kind
        let origin: String
        let message: String
        var defaultText: String = ""
    }
    struct Response {
        var accepted = false
        var text: String?
        static let cancelled = Response()
    }
    typealias Presenter = (NSAlert, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void
    static let shared = JavaScriptDialogs()
    private let present: Presenter
    private let now: () -> TimeInterval
    private final class WindowBudget {
        var times: [TimeInterval] = []
    }
    @MainActor private final class Pending {
        weak var web: WKWebView?
        weak var window: NSWindow?
        let url: URL?
        let alert: NSAlert
        let field: NSTextField?
        let completion: (Response) -> Void
        var observers: [NSObjectProtocol] = []
        init(web: WKWebView, window: NSWindow, alert: NSAlert, field: NSTextField?, completion: @escaping (Response) -> Void) {
            self.web = web; self.window = window; url = web.url
            self.alert = alert; self.field = field; self.completion = completion
        }
    }
    private let budgets = NSMapTable<NSWindow, WindowBudget>.weakToStrongObjects()
    private let suppressed = NSHashTable<WKWebView>.weakObjects()
    private var pending: [UUID: Pending] = [:]

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         present: @escaping Presenter = { alert, window, completion in
             alert.beginSheetModal(for: window, completionHandler: completion)
         }) {
        self.now = now; self.present = present
    }

    static func originLabel(_ origin: WKSecurityOrigin) -> String {
        originLabel(scheme: origin.protocol, host: origin.host, port: origin.port)
    }

    static func originLabel(scheme: String, host: String, port: Int) -> String {
        if scheme == "file" { return "a local file" }
        guard ["http", "https", "webkit-extension", "safari-web-extension"].contains(scheme), !host.isEmpty,
              host.unicodeScalars.allSatisfy({ $0.isASCII && !CharacterSet.controlCharacters.contains($0) }) else {
            return "an unknown origin"
        }
        let hostname = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        let defaultPort = scheme == "https" ? 443 : 80
        return "\(scheme)://\(hostname)" + (port > 0 && port != defaultPort ? ":\(port)" : "")
    }

    func request(_ request: Request, from web: WKWebView, completion: @escaping (Response) -> Void) {
        guard let window = web.window, Self.isVisible(web, in: window), window.isKeyWindow,
              window.attachedSheet == nil, !suppressed.contains(web),
              !pending.values.contains(where: { $0.window === window }) else {
            completion(.cancelled); return
        }
        let budget = budgets.object(forKey: window) ?? WindowBudget()
        budgets.setObject(budget, forKey: window)
        let time = now()
        budget.times.removeAll { time - $0 >= 30 }
        // Window-wide so frames, reloads, redirects, and competing panes cannot
        // reset the limit. No queued dialogs and at most three per 30 seconds.
        guard budget.times.count < 3 else { completion(.cancelled); return }
        budget.times.append(time)

        let alert = NSAlert()
        alert.messageText = "JavaScript from \(request.origin)"
        alert.informativeText = String(request.message.prefix(4096))
        alert.addButton(withTitle: "OK")
        if request.kind != .alert { alert.addButton(withTitle: "Cancel") }
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Prevent further dialogs from this page"
        var field: NSTextField?
        if request.kind == .prompt {
            let input = NSTextField(string: String(request.defaultText.prefix(4096)))
            input.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
            alert.accessoryView = input
            alert.window.initialFirstResponder = input
            field = input
        }
        let id = UUID()
        let item = Pending(web: web, window: window, alert: alert, field: field, completion: completion)
        pending[id] = item
        for name in [NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification] {
            item.observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish(id, response: .cancelled) }
            })
        }
        InputDiagnostics.transition(.javascriptDialog, .shown, view: web)
        present(alert, window) { [weak self] result in
            guard let self, let item = self.pending[id] else { return }
            if item.alert.suppressionButton?.state == .on, let web = item.web { self.suppressed.add(web) }
            let valid = item.web.map { web in
                item.window.map { Self.isVisible(web, in: $0) && web.url == item.url } ?? false
            } ?? false
            let accepted = valid && result == .alertFirstButtonReturn
            self.finish(id, response: Response(accepted: accepted, text: accepted ? item.field?.stringValue : nil))
        }
    }

    private static func isVisible(_ web: WKWebView, in window: NSWindow) -> Bool {
        web.window === window && window.isVisible && !window.isMiniaturized
            && !web.isHiddenOrHasHiddenAncestor && !web.visibleRect.isEmpty
    }

    func cancel(for web: WKWebView) {
        for (id, item) in Array(pending) where item.web === web { finish(id, response: .cancelled) }
    }

    func didCommitNavigation(in web: WKWebView) {
        cancel(for: web)
        suppressed.remove(web)
    }

    private func finish(_ id: UUID, response: Response) {
        guard let item = pending.removeValue(forKey: id) else { return }
        for observer in item.observers { NotificationCenter.default.removeObserver(observer) }
        if let parent = item.alert.window.sheetParent { parent.endSheet(item.alert.window, returnCode: .cancel) }
        InputDiagnostics.transition(.javascriptDialog, .hidden, view: item.web)
        item.completion(response)
    }
}
