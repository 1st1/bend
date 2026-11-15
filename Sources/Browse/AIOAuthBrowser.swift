import AppKit
import AuthenticationServices

@MainActor protocol OAuthBrowserSession: AnyObject {
    var presentationContextProvider: (any ASWebAuthenticationPresentationContextProviding)? { get set }
    func start() -> Bool
    func cancel()
}

extension ASWebAuthenticationSession: OAuthBrowserSession {}

// @lat: [[lat.md/architecture/ai#Account sign-in]]
@MainActor final class AIOAuthBrowser: NSObject, ASWebAuthenticationPresentationContextProviding {
    typealias SessionFactory = (URL, ASWebAuthenticationSession.Callback, @escaping ASWebAuthenticationSession.CompletionHandler) -> any OAuthBrowserSession
    let anchor: NSWindow
    private let makeSession: SessionFactory
    private var active = false

    init(anchor: NSWindow, makeSession: @escaping SessionFactory = { url, callback, completion in
        ASWebAuthenticationSession(url: url, callback: callback, completionHandler: completion)
    }) {
        self.anchor = anchor
        self.makeSession = makeSession
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { anchor }

    func authenticate(url: URL, callback: OAuthLoopback) async throws -> URL {
        try Task.checkCancellation()
        guard anchor.isVisible else { throw CancellationError() }
        active = true
        // A nil callback scheme can complete on an ordinary HTTPS redirect.
        // Reserve a unique, unused scheme so only the validated HTTP loopback
        // listener completes sign-in; cancel the browser after that result.
        let browserCallback = ASWebAuthenticationSession.Callback.customScheme("bend-auth-" + UUID().uuidString.lowercased())
        let session = makeSession(url, browserCallback) { [weak self] _, error in
            Task { @MainActor in
                guard self?.active == true else { return }
                let failure = error as NSError?
                if failure?.domain == ASWebAuthenticationSessionErrorDomain,
                   failure?.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                    callback.cancel()
                } else {
                    callback.cancel(with: error ?? AIOAuthError.invalid("The sign-in window closed before authorization completed."))
                }
            }
        }
        session.presentationContextProvider = self
        let closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: anchor, queue: .main) { _ in
            Task { @MainActor in callback.cancel() }
        }
        defer {
            active = false
            NotificationCenter.default.removeObserver(closing)
            session.cancel()
        }
        guard session.start() else { throw AIOAuthError.invalid("Could not open the sign-in window. Try again.") }
        return try await callback.wait()
    }
}
