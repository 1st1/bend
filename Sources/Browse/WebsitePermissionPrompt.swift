import AppKit
import WebKit
import BrowseCore

@MainActor
final class WebsitePermissionPrompt {
    typealias Presenter = (NSAlert, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void
    private let present: Presenter
    private var pending: (id: UUID, alert: NSAlert, completion: (Bool, Bool) -> Void)?
    private var observers: [NSObjectProtocol] = []

    init(present: @escaping Presenter = { alert, window, completion in
        alert.beginSheetModal(for: window, completionHandler: completion)
    }) { self.present = present }

    func request(_ permissions: [WebsitePermission], origin: String, top: String,
                 from web: WKWebView, completion: @escaping (Bool, Bool) -> Void) {
        guard pending == nil, let window = web.window, window.isKeyWindow,
              window.isVisible, !window.isMiniaturized, window.attachedSheet == nil,
              !web.isHiddenOrHasHiddenAncestor, !web.visibleRect.isEmpty else {
            completion(false, false); return
        }
        let alert = NSAlert()
        alert.messageText = "Allow \(origin) to use your \(permissions.map { $0.title.lowercased() }.joined(separator: " and "))?"
        alert.informativeText = origin == top
            ? "Only allow access if you trust this website. You can change saved choices in Settings → Websites."
            : "This request comes from content embedded in \(top). Access applies to this request only."
        alert.addButton(withTitle: "Don’t Allow")
        alert.addButton(withTitle: "Allow")
        alert.showsSuppressionButton = origin == top
        alert.suppressionButton?.title = "Remember my choice for this website"
        let id = UUID(), url = web.url
        pending = (id, alert, completion)
        for name in [NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            })
        }
        present(alert, window) { [weak self, weak web, weak window] response in
            guard let self, self.pending?.id == id else { return }
            let valid = web != nil && window != nil && web?.window === window && web?.url == url
                && web?.isHiddenOrHasHiddenAncestor == false && window?.isVisible == true && window?.isMiniaturized == false
            let explicit = response == .alertFirstButtonReturn || response == .alertSecondButtonReturn
            self.finish(allowed: valid && response == .alertSecondButtonReturn,
                        remember: valid && explicit && origin == top && alert.suppressionButton?.state == .on)
        }
    }

    func cancel() { finish(allowed: false, remember: false) }

    private func finish(allowed: Bool, remember: Bool) {
        guard let item = pending else { return }
        pending = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if let window = item.alert.window.sheetParent { window.endSheet(item.alert.window, returnCode: .cancel) }
        item.completion(allowed, remember)
    }
}
