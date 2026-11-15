import AppKit
import WebKit

// @lat: [[lat.md/architecture/web-pages#Website file uploads]]
@MainActor
final class WebsiteFileUpload {
    typealias Presenter = (NSOpenPanel, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void
    private let present: Presenter
    init(present: @escaping Presenter = { panel, window, completion in
        panel.beginSheetModal(for: window, completionHandler: completion)
    }) { self.present = present }
    private(set) var panel: NSOpenPanel?
    private var completion: (([URL]?) -> Void)?
    private var observers: [NSObjectProtocol] = []

    func request(from web: WKWebView, origin: String? = nil, multiple: Bool, directories: Bool,
                 completion: @escaping ([URL]?) -> Void) {
        guard self.completion == nil, let window = web.window, window.isKeyWindow,
              window.isVisible, !window.isMiniaturized, window.attachedSheet == nil,
              !web.isHiddenOrHasHiddenAncestor, !web.visibleRect.isEmpty else {
            completion(nil); return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = !directories
        panel.canChooseDirectories = directories
        panel.allowsMultipleSelection = multiple
        panel.canCreateDirectories = false
        panel.prompt = "Upload"
        panel.message = "Choose \(directories ? "a folder" : "files") to share with \(origin ?? web.url?.host ?? "this website")."
        self.panel = panel
        self.completion = completion
        let url = web.url
        for name in [NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel() }
            })
        }
        present(panel, window) { [weak self, weak web, weak window] response in
            guard let self, self.panel === panel else { return }
            let valid = web != nil && window != nil && web?.window === window
                && web?.url == url && web?.isHiddenOrHasHiddenAncestor == false
                && window?.isVisible == true && window?.isMiniaturized == false
            self.finish(response == .OK && valid ? panel.urls : nil)
        }
    }

    func cancel() {
        let panel = panel
        finish(nil)
        panel?.cancel(nil)
    }

    private func finish(_ urls: [URL]?) {
        let callback = completion
        completion = nil
        panel = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        callback?(urls)
    }
}
