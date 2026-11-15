import AppKit
import WebKit

// @lat: [[lat.md/architecture/ai#Action approval]]
@MainActor final class AIActionApproval {
    typealias Presenter = (NSAlert, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void
    private let present: Presenter
    private var continuation: CheckedContinuation<Bool, Never>?
    private var alert: NSAlert?
    private var observers: [NSObjectProtocol] = []

    init(present: @escaping Presenter = { alert, window, completion in
        alert.beginSheetModal(for: window, completionHandler: completion)
    }) { self.present = present }

    static func confirm(_ details: String, in web: WKWebView) async -> Bool {
        await AIActionApproval().request(details, in: web)
    }

    func request(_ details: String, in web: WKWebView) async -> Bool {
        guard !Task.isCancelled, continuation == nil, let window = web.window,
              window.isKeyWindow, window.isVisible, !window.isMiniaturized,
              !web.isHiddenOrHasHiddenAncestor, !web.visibleRect.isEmpty,
              window.attachedSheet == nil else { return false }
        let alert = NSAlert()
        alert.messageText = "Allow this AI browser action?"
        alert.informativeText = "Review the page and exact action below. Clicking or filling can submit data or change your account through the website’s scripts."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Allow Once")
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = ""
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 220))
        scroll.hasVerticalScroller = true
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.isRichText = false
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.string = details
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        alert.accessoryView = scroll
        self.alert = alert
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                guard !Task.isCancelled else { finish(false); return }
                for name in [NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification] {
                    observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.finish(false) }
                    })
                }
                present(alert, window) { [weak self, weak web, weak window] response in
                    let visible = web.map { web in
                        window.map { web.window === $0 && $0.isVisible && !$0.isMiniaturized
                            && !web.isHiddenOrHasHiddenAncestor && !web.visibleRect.isEmpty } ?? false
                    } ?? false
                    self?.finish(visible && response == .alertSecondButtonReturn)
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish(false) }
        }
    }

    private func finish(_ accepted: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        if let alert, let parent = alert.window.sheetParent { parent.endSheet(alert.window, returnCode: .cancel) }
        alert = nil
        continuation.resume(returning: accepted)
    }
}
