import Foundation
import WebKit
import UserNotifications

// @lat: [[architecture#Extension compatibility adapters]]
@available(macOS 15.4, *)
@MainActor
final class ExtensionCompatibility: NSObject, WKScriptMessageHandlerWithReply {
    weak var manager: ExtensionManager?
    let notifications: any ExtensionNotificationDelivering
    private var pages: [UUID: NSHashTable<WKWebView>] = [:]
    private var notices: [UUID: [String: [String: Any]]] = [:]
    private let dispatcher = "__browseExtensionEvent_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")

    init(notifications: any ExtensionNotificationDelivering = ExtensionNotifications()) {
        self.notifications = notifications
        super.init()
        notifications.onResponse = { [weak self] key, action in self?.notificationResponse(key: key, action: action) }
    }

    func configure(_ configuration: WKWebViewConfiguration) {
        let content = configuration.userContentController
        content.addScriptMessageHandler(self, contentWorld: .page, name: "browseExtension")
        content.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    func authorizedContext(origin: WKSecurityOrigin, mainFrame: Bool) -> (UUID, WKWebExtensionContext)? {
        guard mainFrame, let manager else { return nil }
        return manager.contexts.first { _, context in
            context.isLoaded && context.baseURL.scheme == origin.protocol && context.baseURL.host == origin.host
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let (id, context) = authorizedContext(origin: message.frameInfo.securityOrigin, mainFrame: message.frameInfo.isMainFrame),
              message.webView?.url?.scheme == context.baseURL.scheme, message.webView?.url?.host == context.baseURL.host,
              let body = message.body as? [String: Any], let operation = body["operation"] as? String else {
            replyHandler(nil, "Only enabled extension pages can use this API."); return
        }
        if let web = message.webView {
            if pages[id] == nil { pages[id] = NSHashTable.weakObjects() }
            pages[id]?.add(web)
        }
        if operation == "register" { replyHandler(true, nil); return }
        guard context.hasPermission(.init(rawValue: "notifications")) else {
            replyHandler(nil, "The extension does not have notifications permission."); return
        }
        Task { @MainActor in
            do {
                let result = try await notificationOperation(operation, id: id, name: context.webExtension.displayName ?? "Extension", body: body, expectedContext: context)
                guard context.isLoaded else { replyHandler(nil, "The extension was disabled."); return }
                replyHandler(result, nil)
            } catch { replyHandler(nil, error.localizedDescription) }
        }
    }

    private func key(_ id: UUID, _ notification: String) -> String {
        "browse-extension:\(id.uuidString):\(Data(notification.utf8).base64EncodedString())"
    }

    func notificationOperation(_ operation: String, id: UUID, name: String, body: [String: Any], expectedContext: WKWebExtensionContext? = nil) async throws -> Any {
        func failure(_ text: String) -> NSError { NSError(domain: "Browse.Extensions", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
        if operation == "getPermissionLevel" { return await notifications.permission() ? "granted" : "denied" }
        if operation == "getAll" {
            let active = await notifications.keys()
            return Dictionary(uniqueKeysWithValues: (notices[id] ?? [:]).keys.filter { active.contains(key(id, $0)) }.map { ($0, true) })
        }
        guard let notificationID = body["id"] as? String, !notificationID.isEmpty, notificationID.utf8.count <= 512 else {
            throw failure("A notification ID of 1–512 bytes is required.")
        }
        let key = key(id, notificationID)
        if operation == "clear" {
            let exists = await notifications.keys().contains(key)
            notifications.remove(keys: [key]); notices[id]?[notificationID] = nil
            if exists { emit(id, event: "notifications.onClosed", arguments: [notificationID, false]) }
            return exists
        }
        guard operation == "create" || operation == "update", let supplied = body["options"] as? [String: Any] else {
            throw failure("Unknown notification operation or invalid options.")
        }
        if operation == "update", notices[id]?[notificationID] == nil { return false }
        let options = operation == "update" ? (notices[id]?[notificationID] ?? [:]).merging(supplied) { _, new in new } : supplied
        guard options["type"] as? String == "basic", let title = options["title"] as? String,
              let message = options["message"] as? String, title.count <= 512, message.count <= 4096 else {
            throw failure("Browse supports basic notifications with a title and message.")
        }
        let buttonOptions = options["buttons"] as? [[String: Any]] ?? []
        let buttons = buttonOptions.compactMap { $0["title"] as? String }
        guard buttons.count == buttonOptions.count, buttons.count <= 2 else { throw failure("Notifications support at most two titled buttons.") }
        guard (notices[id]?.count ?? 0) < 64 || notices[id]?[notificationID] != nil else { throw failure("Too many active notifications.") }
        try await notifications.post(key: key, title: "\(name): \(title)", message: message, buttons: buttons)
        // A permission prompt can outlive disable/uninstall. Do not leave a notification behind.
        if let expectedContext, (!expectedContext.isLoaded || manager?.contexts[id] !== expectedContext || !expectedContext.hasPermission(.init(rawValue: "notifications"))) {
            notifications.remove(keys: [key]); throw failure("The extension was disabled.")
        }
        notices[id, default: [:]][notificationID] = options
        return operation == "update" ? true : notificationID
    }

    func stop(_ id: UUID) {
        notifications.remove(keys: (notices[id] ?? [:]).keys.map { key(id, $0) })
        notices[id] = nil; pages[id] = nil
    }

    private func notificationResponse(key: String, action: String) {
        let parts = key.split(separator: ":", maxSplits: 2)
        guard parts.count == 3, parts[0] == "browse-extension", let id = UUID(uuidString: String(parts[1])),
              let data = Data(base64Encoded: String(parts[2])), let notification = String(data: data, encoding: .utf8),
              manager?.contexts[id]?.hasPermission(.init(rawValue: "notifications")) == true else { return }
        if action == UNNotificationDefaultActionIdentifier { emit(id, event: "notifications.onClicked", arguments: [notification]) }
        else if action == UNNotificationDismissActionIdentifier {
            notices[id]?[notification] = nil
            emit(id, event: "notifications.onClosed", arguments: [notification, true])
        } else if action.hasPrefix("button:"), let index = Int(action.dropFirst(7)) {
            emit(id, event: "notifications.onButtonClicked", arguments: [notification, index])
        }
    }

    private func emit(_ id: UUID, event: String, arguments: [Any]) {
        guard let context = manager?.contexts[id], context.isLoaded else { return }
        for web in pages[id]?.allObjects ?? [] {
            guard web.url?.scheme == context.baseURL.scheme, web.url?.host == context.baseURL.host else { continue }
            Task { _ = try? await web.callAsyncJavaScript("globalThis[dispatcher]?.(event, args)",
                arguments: ["dispatcher": dispatcher, "event": event, "args": arguments], in: nil, contentWorld: .page) }
        }
    }

    var script: String {
        Self.javascript.replacingOccurrences(of: "__DISPATCHER__", with: dispatcher)
    }

    static let javascript = #"""
    (() => {
        if (location.protocol !== 'webkit-extension:' || !globalThis.browser?.runtime?.id) return;
        const native = globalThis.browser;
        const bridge = window.webkit.messageHandlers.browseExtension;
        const call = (operation, values = {}) => bridge.postMessage({operation, ...values});
        const events = new Map();
        function event(name) {
            const listeners = new Map();
            const result = {
                addListener(listener, filter) {
                    if (typeof listener !== 'function') throw new TypeError('Listener must be a function');
                    if (filter && Object.keys(filter).some(key => key !== 'url')) throw new TypeError('Only URL filters are supported');
                    listeners.set(listener, filter);
                },
                removeListener(listener) { listeners.delete(listener); },
                hasListener(listener) { return listeners.has(listener); },
                hasListeners() { return listeners.size > 0; }
            };
            events.set(name, args => {
                for (const [listener, filter] of listeners) {
                    if (filter?.url && !filter.url.some(rule => matchesURL(args[0].url, rule))) continue;
                    try { listener(...args); } catch (error) { console.error(error); }
                }
            });
            return result;
        }
        function matchesURL(value, rule) {
            const url = new URL(value);
            const parts = {host: url.hostname, path: url.pathname, query: url.search.slice(1), url: value};
            return Object.entries(rule).every(([key, expected]) => {
                if (key === 'schemes') return expected.includes(url.protocol.slice(0, -1));
                if (key === 'ports') {
                    const actual = +(url.port || (url.protocol === 'https:' ? 443 : url.protocol === 'http:' ? 80 : 0));
                    return expected.some(port => Array.isArray(port) ? actual >= port[0] && actual <= port[1] : actual === port);
                }
                for (const [part, actual] of Object.entries(parts)) {
                    if (key === part + 'Equals') return actual === expected;
                    if (key === part + 'Contains') return actual.includes(expected);
                    if (key === part + 'Prefix') return actual.startsWith(expected);
                    if (key === part + 'Suffix') return actual.endsWith(expected);
                }
                if (key === 'urlMatches') return new RegExp(expected).test(value);
                if (key === 'originAndPathMatches') return new RegExp(expected).test(url.origin + url.pathname);
                return false;
            });
        }
        Object.defineProperty(globalThis, '__DISPATCHER__', {value: (name, args) => events.get(name)?.(args)});
        function callbackResult(promise, callback) {
            if (!callback) return promise;
            promise.then(value => callback(value), error => {
                // lastError exists only during the callback, matching Chromium semantics.
                lastError = {message: String(error?.message || error)};
                try { callback(); } finally { lastError = undefined; }
            });
        }
        let lastError;
        const requested = native.runtime.getManifest().permissions || [];
        let notifications = native.notifications;
        if (!notifications && requested.includes('notifications')) {
            notifications = {
                onClicked: event('notifications.onClicked'), onButtonClicked: event('notifications.onButtonClicked'),
                onClosed: event('notifications.onClosed'), onPermissionLevelChanged: event('notifications.onPermissionLevelChanged'),
                create(id, options, callback) {
                    if (typeof id !== 'string') { callback = options; options = id; id = crypto.randomUUID(); }
                    if (!id) id = crypto.randomUUID();
                    return callbackResult(call('create', {id, options}), callback);
                },
                update(id, options, callback) { return callbackResult(call('update', {id, options}), callback); },
                clear(id, callback) { return callbackResult(call('clear', {id}), callback); },
                getAll(callback) { return callbackResult(call('getAll'), callback); },
                getPermissionLevel(callback) { return callbackResult(call('getPermissionLevel'), callback); }
            };
            // WebKit keeps extension event dispatch anchored to the native browser namespace.
            native.notifications = notifications;
            let previousPermission;
            const refreshPermission = async () => {
                try {
                    const permission = await call('getPermissionLevel');
                    if (previousPermission !== undefined && previousPermission !== permission)
                        events.get('notifications.onPermissionLevelChanged')?.([permission]);
                    previousPermission = permission;
                } catch { /* Permission may have been revoked or the context unloaded. */ }
            };
            refreshPermission();
            setInterval(refreshPermission, 15000);
            document.addEventListener('visibilitychange', refreshPermission);
        }
        let navigation = native.webNavigation;
        if (navigation && !navigation.onCreatedNavigationTarget && requested.includes('webNavigation')) {
            const created = event('webNavigation.onCreatedNavigationTarget');
            const original = navigation;
            navigation = new Proxy(original, {get(target, property) {
                if (property === 'onCreatedNavigationTarget') return created;
                const value = Reflect.get(target, property, target);
                return typeof value === 'function' ? value.bind(target) : value;
            }});
            native.tabs.onCreated.addListener(async tab => {
                if (tab.openerTabId == null || !tab.url) return;
                if (!await native.permissions.contains({permissions:['webNavigation']})) return;
                events.get('webNavigation.onCreatedNavigationTarget')?.([{
                    tabId: tab.id, sourceTabId: tab.openerTabId, sourceFrameId: 0,
                    sourceProcessId: -1, url: tab.url, timeStamp: Date.now()
                }]);
            });
        }
        const runtime = new Proxy(native.runtime, {get(target, property) {
            if (property === 'lastError' && lastError) return lastError;
            const value = Reflect.get(target, property, target);
            return typeof value === 'function' ? value.bind(target) : value;
        }});
        // Leave browser intact so WebKit can deliver its native events. Chrome's
        // namespace supplies the additional APIs used by Firefox 1Password.
        globalThis.chrome = new Proxy(native, {get(target, property) {
            if (property === 'notifications') return notifications;
            if (property === 'webNavigation') return navigation;
            if (property === 'runtime') return runtime;
            const value = Reflect.get(target, property, target);
            return typeof value === 'function' ? value.bind(target) : value;
        }});
        call('register').catch(error => console.error('Browse extension bridge:', String(error)));
    })();
    """#
}
