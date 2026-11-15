import AppKit
import WebKit
import BrowseCore

extension PageController {
    var permissionOrigin: String? { webView.url.flatMap(WebsitePermission.origin) }

    func isBlocked(_ permission: WebsitePermission, origin: String) -> Bool {
        websiteSettings?.values.blockedPermissions[origin]?.contains(permission) == true
    }

    func setBlocked(_ blocked: Bool, permission: WebsitePermission, origin: String) {
        websiteSettings?.setBlocked(blocked, permission: permission, origin: origin)
    }

    // @lat: [[lat.md/architecture/web-pages#Website permissions]]
    func permissionDecision(_ permissions: [WebsitePermission], requesting url: URL?) -> WKPermissionDecision {
        guard let origin = url.flatMap(WebsitePermission.origin), let top = permissionOrigin else { return .deny }
        guard !permissions.contains(where: { isBlocked($0, origin: origin) || isBlocked($0, origin: top) }) else { return .deny }
        for permission in permissions { captureRequestOrigins[permission, default: []].formUnion([origin, top]) }
        // Embedded content cannot inherit its embedder's saved Allow choice.
        let allowed = permissions.allSatisfy {
            websiteSettings?.values.permission($0, for: origin) == .allow
        }
        return allowed && origin == top ? .grant : .prompt
    }

    func requestPermission(_ permissions: [WebsitePermission], origin: WKSecurityOrigin,
                           completion: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        let url = URL(string: JavaScriptDialogs.originLabel(origin))
        let decision = permissionDecision(permissions, requesting: url)
        guard decision == .prompt, let requesting = url.flatMap(WebsitePermission.origin),
              let top = permissionOrigin else { completion(decision); return }
        let revision = aiNavigationRevision
        permissionPrompt.request(permissions, origin: requesting, top: top, from: webView) { [weak self] allow, remember in
            guard let self, self.aiNavigationRevision == revision, self.permissionOrigin == top else {
                completion(.deny); return
            }
            // A settings change while a sheet is open may have blocked access.
            guard self.permissionDecision(permissions, requesting: url) != .deny else {
                completion(.deny); return
            }
            if remember {
                self.websiteSettings?.setPermissions(allow ? .allow : .block, permissions: permissions, origin: requesting)
            }
            completion(allow ? .grant : .deny)
        }
    }

    func refreshCaptureState() {
        cameraCaptureState = webView.cameraCaptureState
        microphoneCaptureState = webView.microphoneCaptureState
    }

    func stopCapture() {
        webView.setCameraCaptureState(.none) {}
        webView.setMicrophoneCaptureState(.none) {}
    }

    func applyCaptureRestrictions() {
        let blocks = websiteSettings?.values.blockedPermissions ?? [:]
        for permission in [WebsitePermission.camera, .microphone] {
            let revoked = blocks.contains { origin, permissions in
                permissions.contains(permission)
                    && lastPermissionBlocks[origin]?.contains(permission) != true
                    && (captureRequestOrigins[permission]?.contains(origin) == true || permissionOrigin == origin)
            }
            if revoked {
                if permission == .camera { webView.setCameraCaptureState(.none) {} }
                else { webView.setMicrophoneCaptureState(.none) {} }
            }
        }
        lastPermissionBlocks = blocks
    }

    @objc(webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:)
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        let permissions: [WebsitePermission]
        switch type {
        case .camera: permissions = [.camera]
        case .microphone: permissions = [.microphone]
        case .cameraAndMicrophone: permissions = [.camera, .microphone]
        @unknown default: decisionHandler(.deny); return
        }
        requestPermission(permissions, origin: origin, completion: decisionHandler)
    }

    // Explicit selectors keep the macOS 27 public callback buildable with
    // the macOS 26 SDK. macOS 26 uses the equivalent WebKit SPI below.
    @objc(webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:)
    func webView(_ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        requestPermission([.location], origin: origin, completion: decisionHandler)
    }

    @objc(_webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:)
    func legacyGeolocation(_ webView: WKWebView, origin: WKSecurityOrigin,
                           frame: WKFrameInfo, decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        requestPermission([.location], origin: origin, completion: decisionHandler)
    }

    @objc(webView:runOpenPanelWithParameters:initiatedByFrame:completionHandler:)
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void) {
        fileUpload.request(from: webView, origin: JavaScriptDialogs.originLabel(frame.securityOrigin), multiple: parameters.allowsMultipleSelection,
                           directories: parameters.allowsDirectories, completion: completionHandler)
    }
}
