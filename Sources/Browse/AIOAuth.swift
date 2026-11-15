import AppKit
import CryptoKit
import Network
import Security
import AI

enum AIAccountProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case openai, vercel
    var id: String { rawValue }
    var title: String { self == .openai ? "OpenAI" : "Vercel" }
    var issuer: String { self == .openai ? "https://auth.openai.com" : "https://vercel.com" }
    var authorize: String { self == .openai ? issuer + "/api/accounts/authorize" : issuer + "/oauth/authorize" }
    var token: String { self == .openai ? issuer + "/api/accounts/oauth/token" : "https://api.vercel.com/login/oauth/token" }
    var revoke: String { self == .openai ? issuer + "/api/accounts/oauth/revoke" : "https://api.vercel.com/login/oauth/token/revoke" }
    var jwks: String { issuer + (self == .openai ? "/.well-known/jwks.json" : "/.well-known/jwks") }
}

struct AIAccountSession: Codable, Sendable {
    var clientID: String
    var subject: String = ""
    var email: String = ""
    var accessToken: String = ""
    var refreshToken: String = ""
    var idToken: String = ""
    var scopes: String = ""
    var expiresAt: Date = .distantPast
    var signedIn: Bool { !accessToken.isEmpty }
    mutating func clearTokens() {
        accessToken = ""; refreshToken = ""; idToken = ""; scopes = ""; expiresAt = .distantPast
    }
}

enum AIOAuthError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

struct AIOAuthAttempt {
    let state: String
    let nonce: String
    let verifier: String
    init() throws {
        state = try Self.random(); nonce = try Self.random(); verifier = try Self.random()
    }
    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw AIOAuthError.invalid("Could not prepare secure sign-in.")
        }
        return Data(bytes).oauthBase64
    }
    var challenge: String { Data(SHA256.hash(data: Data(verifier.utf8))).oauthBase64 }

    func authorizationURL(provider: AIAccountProvider, clientID: String, redirect: URL, hostID: String) -> URL {
        var fields = ["client_id": clientID, "redirect_uri": redirect.absoluteString, "response_type": "code",
                      "state": state, "nonce": nonce, "code_challenge": challenge, "code_challenge_method": "S256",
                      "scope": "openid email profile offline_access"]
        if provider == .openai {
            fields["scope"] = "openid email profile offline_access resource.invoke chatgpt.tokens.use.direct"
            fields["resource"] = "https://api.openai.com/v1"
            fields["ext_agent_host_id"] = hostID
            if clientID == "dynamic_agent_client" { fields["agent_name_hint"] = "Bend" }
        }
        var url = URLComponents(string: provider.authorize)!
        url.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return url.url!
    }

    func callback(_ url: URL, redirect: URL, clientID: String) throws -> (code: String, clientID: String) {
        guard url.scheme == redirect.scheme, url.host == redirect.host, url.port == redirect.port, url.path == redirect.path,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw AIOAuthError.invalid("Invalid sign-in callback.")
        }
        let items = components.queryItems ?? []
        guard Set(items.map(\.name)).count == items.count else { throw AIOAuthError.invalid("Duplicate sign-in parameters.") }
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        guard values["state"] == state else { throw AIOAuthError.invalid("Sign-in state did not match. Try again.") }
        if values["error"] != nil { throw AIOAuthError.invalid("Sign-in was declined or cancelled.") }
        let issued = values["client_id"] ?? clientID
        guard !issued.isEmpty, issued != "dynamic_agent_client",
              clientID == "dynamic_agent_client" || issued == clientID,
              let code = values["code"], !code.isEmpty else { throw AIOAuthError.invalid("Sign-in did not return a valid registration.") }
        return (code, issued)
    }
}

extension Data {
    var oauthBase64: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    init?(oauthBase64 value: String) {
        let raw = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        self.init(base64Encoded: raw + String(repeating: "=", count: (4 - raw.count % 4) % 4))
    }
}

// @lat: [[lat.md/architecture/ai#Account sign-in]]
@MainActor final class AIOAuthAccounts {
    private(set) var sessions: [String: AIAccountSession] = [:]
    private let storage: any AICredentialStore
    private let transport: any HTTPTransport
    private let defaults: UserDefaults
    private var refreshes: [AIAccountProvider: Task<String, Error>] = [:]
    private var generations: [AIAccountProvider: Int] = [:]
    init(storage: any AICredentialStore = GatewayCredential(service: AppProfile.current.bundleIdentifier + ".ai-accounts"),
         transport: any HTTPTransport = URLSessionTransport(), defaults: UserDefaults = AppProfile.current.defaults) {
        self.storage = storage; self.transport = transport; self.defaults = defaults
    }
    func restore() async throws {
        let generation = generations
        if let saved = try await storage.readAsync() {
            try Task.checkCancellation()
            guard generations == generation else { return }
            sessions = try JSONDecoder().decode([String: AIAccountSession].self, from: Data(saved.utf8))
        }
    }
    private func persist() throws { try storage.save(String(decoding: JSONEncoder().encode(sessions), as: UTF8.self)) }
    func session(_ provider: AIAccountProvider) -> AIAccountSession? { sessions[provider.rawValue] }

    func login(_ provider: AIAccountProvider, vercelClientID: String) async throws {
        let clientID = provider == .openai ? (session(provider)?.clientID ?? "dynamic_agent_client") : vercelClientID
        guard !clientID.isEmpty else { throw AIOAuthError.invalid("Configure Bend’s public Vercel client ID before signing in.") }
        let generation = generations[provider, default: 0]
        let previous = session(provider)
        let attempt = try AIOAuthAttempt()
        guard let anchor = NSApp.modalWindow ?? NSApp.keyWindow ?? NSApp.mainWindow else {
            throw AIOAuthError.invalid("Open Settings to sign in.")
        }
        let callback = OAuthLoopback()
        let redirect = try await callback.start(port: provider == .vercel ? 17849 : 0, state: attempt.state)
        defer { callback.cancel() }
        let hostID = defaults.string(forKey: "ai.openai.host") ?? "urn:uuid:" + UUID().uuidString.lowercased()
        defaults.set(hostID, forKey: "ai.openai.host")
        let browser = AIOAuthBrowser(anchor: anchor)
        let authorizationURL = attempt.authorizationURL(provider: provider, clientID: clientID, redirect: redirect, hostID: hostID)
        let response = try await browser.authenticate(url: authorizationURL, callback: callback)
        let result = try attempt.callback(response, redirect: redirect, clientID: clientID)
        try Task.checkCancellation()
        guard generations[provider, default: 0] == generation else { throw CancellationError() }
        // Keep a new registration even if its one-time code expires.
        if previous == nil {
            sessions[provider.rawValue] = AIAccountSession(clientID: result.clientID)
            try persist()
        }
        var fields = ["grant_type": "authorization_code", "client_id": result.clientID, "code": result.code,
                      "code_verifier": attempt.verifier, "redirect_uri": redirect.absoluteString]
        if provider == .openai { fields["resource"] = "https://api.openai.com/v1" }
        let data = try await request(provider.token, fields: fields)
        let tokens = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard let idToken = tokens.id_token else { throw AIOAuthError.invalid("The provider did not return a verified identity.") }
        let keys = try await request(provider.jwks)
        let identity = try OAuthIdentity.verify(idToken, jwks: keys, issuer: provider.issuer, audience: result.clientID, nonce: attempt.nonce)
        if let previous, !previous.subject.isEmpty, previous.clientID == result.clientID, previous.subject != identity.subject {
            throw AIOAuthError.invalid("This sign-in belongs to another account.")
        }
        var session = AIAccountSession(clientID: result.clientID, subject: identity.subject, email: identity.email)
        try session.apply(tokens, provider: provider)
        try Task.checkCancellation()
        guard generations[provider, default: 0] == generation else { throw CancellationError() }
        sessions[provider.rawValue] = session
        try persist()
    }

    func accessToken(_ provider: AIAccountProvider) async throws -> String {
        guard let session = session(provider), session.signedIn else { throw AIOAuthError.invalid("Log in to \(provider.title) in Settings → AI.") }
        if session.expiresAt.timeIntervalSinceNow > 90 { return session.accessToken }
        if let pending = refreshes[provider] { return try await pending.value }
        let generation = generations[provider, default: 0]
        let task = Task { @MainActor in
            guard !session.refreshToken.isEmpty else { throw AIOAuthError.invalid("Your \(provider.title) session expired. Log in again.") }
            var fields = ["grant_type": "refresh_token", "refresh_token": session.refreshToken, "client_id": session.clientID]
            if provider == .openai { fields["resource"] = "https://api.openai.com/v1" }
            let data = try await self.request(provider.token, fields: fields)
            let response = try JSONDecoder().decode(TokenResponse.self, from: data)
            var renewed = session
            try renewed.apply(response, provider: provider)
            try Task.checkCancellation()
            guard self.generations[provider, default: 0] == generation else { throw CancellationError() }
            self.sessions[provider.rawValue] = renewed
            try self.persist()
            return renewed.accessToken
        }
        refreshes[provider] = task
        defer { refreshes[provider] = nil }
        return try await task.value
    }

    /// Ends local access even if the provider is offline. The caller displays a revocation warning.
    func logout(_ provider: AIAccountProvider) async throws -> Bool {
        generations[provider, default: 0] += 1
        refreshes.removeValue(forKey: provider)?.cancel()
        guard var saved = session(provider) else { return true }
        let token = saved.refreshToken.isEmpty ? saved.accessToken : saved.refreshToken
        let hint = saved.refreshToken.isEmpty ? "access_token" : "refresh_token"
        saved.clearTokens()
        sessions[provider.rawValue] = saved
        try persist()
        guard !token.isEmpty else { return true }
        for attempt in 0..<2 {
            do {
                _ = try await request(provider.revoke, fields: ["token": token, "token_type_hint": hint, "client_id": saved.clientID])
                return true
            } catch {
                if attempt == 0 { try? await Task.sleep(for: .milliseconds(500)) }
            }
        }
        return false
    }

    func request(_ address: String, fields: [String: String]? = nil, bearer: String? = nil) async throws -> Data {
        var request = URLRequest(url: URL(string: address)!)
        request.timeoutInterval = 30
        if let fields {
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            request.httpBody = Data(fields.sorted { $0.key < $1.key }.map {
                $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)!
            }.joined(separator: "&").utf8)
        }
        if let bearer { request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization") }
        var data = Data(); var status = 0
        for try await event in transport.send(request) {
            try Task.checkCancellation()
            switch event {
            case .response(let code): status = code
            case .data(let chunk):
                guard data.count + chunk.count <= 2_000_000 else { throw AIOAuthError.invalid("Account response was too large.") }
                data.append(chunk)
            }
        }
        guard (200..<300).contains(status) else { throw AIOAuthError.invalid("Account request failed (HTTP \(status)). Log in again or try later.") }
        return data
    }
}

private struct TokenResponse: Decodable {
    let access_token: String
    let refresh_token: String?
    let id_token: String?
    let token_type: String
    let expires_in: Double
    let scope: String?
}
private extension AIAccountSession {
    mutating func apply(_ token: TokenResponse, provider: AIAccountProvider) throws {
        let granted = token.scope ?? scopes
        guard !token.access_token.isEmpty, token.token_type.lowercased() == "bearer", token.expires_in > 0,
              provider != .openai || granted.split(separator: " ").contains("chatgpt.tokens.use.direct") else {
            throw AIOAuthError.invalid("Sign-in did not authorize AI usage. Log in again and enable plan usage.")
        }
        accessToken = token.access_token; refreshToken = token.refresh_token ?? refreshToken
        idToken = token.id_token ?? idToken; scopes = granted; expiresAt = Date().addingTimeInterval(token.expires_in)
    }
}

enum OAuthIdentity {
    static func verify(_ token: String, jwks: Data, issuer: String, audience: String, nonce: String, now: Date = Date()) throws -> (subject: String, email: String) {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let headerData = Data(oauthBase64: parts[0]), let claimsData = Data(oauthBase64: parts[1]),
              let signature = Data(oauthBase64: parts[2]),
              let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              header["alg"] as? String == "RS256", let kid = header["kid"] as? String,
              let document = try JSONSerialization.jsonObject(with: jwks) as? [String: Any],
              let keys = document["keys"] as? [[String: Any]],
              let key = keys.first(where: { $0["kid"] as? String == kid && $0["kty"] as? String == "RSA" }),
              key["use"] == nil || key["use"] as? String == "sig",
              let n = key["n"] as? String, let e = key["e"] as? String,
              let modulus = Data(oauthBase64: n), let exponent = Data(oauthBase64: e),
              (256...1024).contains(modulus.count), (1...8).contains(exponent.count) else {
            throw AIOAuthError.invalid("Could not verify the sign-in identity.")
        }
        func der(_ tag: UInt8, _ data: Data) -> Data {
            let count = data.count
            let length: [UInt8] = count < 128 ? [UInt8(count)] : count < 256 ? [0x81, UInt8(count)] : [0x82, UInt8(count >> 8), UInt8(count & 255)]
            return Data([tag] + length) + data
        }
        func integer(_ data: Data) -> Data { der(2, (data.first.map { $0 >= 128 } == true ? Data([0]) : Data()) + data) }
        let encoded = der(0x30, integer(modulus) + integer(exponent))
        guard let publicKey = SecKeyCreateWithData(encoded as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, nil),
              SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, Data((parts[0] + "." + parts[1]).utf8) as CFData, signature as CFData, nil),
              let claims = try JSONSerialization.jsonObject(with: claimsData) as? [String: Any] else {
            throw AIOAuthError.invalid("The sign-in identity signature was invalid.")
        }
        let audiences = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard claims["iss"] as? String == issuer, audiences.contains(audience),
              audiences.count <= 1 || claims["azp"] as? String == audience,
              let expires = claims["exp"] as? Double, expires > now.timeIntervalSince1970,
              (claims["nbf"] as? Double ?? 0) <= now.timeIntervalSince1970 + 30,
              claims["nonce"] as? String == nonce, let subject = claims["sub"] as? String, !subject.isEmpty else {
            throw AIOAuthError.invalid("The sign-in identity claims were invalid or expired.")
        }
        return (subject, claims["email"] as? String ?? subject)
    }
}

// A loopback-only, single-use callback. Wrong-state traffic cannot terminate sign-in.
@MainActor final class OAuthLoopback {
    private var listener: NWListener?
    private var ready: CheckedContinuation<URL, Error>?
    private var result: CheckedContinuation<URL, Error>?
    private var outcome: Result<URL, Error>?
    private var timeout: Task<Void, Never>?
    private var redirect: URL?
    private var state = ""
    private var connections: [NWConnection] = []
    private var connectionTimeouts: [ObjectIdentifier: Task<Void, Never>] = [:]
    func start(port: UInt16, state: String) async throws -> URL {
        self.state = state
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] update in
            Task { @MainActor in
                guard let self else { return }
                switch update {
                case .ready:
                    guard let port = self.listener?.port else { return }
                    let url = URL(string: "http://127.0.0.1:\(port.rawValue)/auth/callback")!
                    self.redirect = url; self.ready?.resume(returning: url); self.ready = nil
                case .failed: self.finish(.failure(AIOAuthError.invalid("Could not start the local sign-in callback. Close other sign-in attempts and retry.")))
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self, self.connections.count < 8 else { connection.cancel(); return }
                self.connections.append(connection)
                self.connectionTimeouts[ObjectIdentifier(connection)] = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    self?.close(connection)
                }
                connection.start(queue: .main)
                self.receive(connection, data: Data())
            }
        }
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(180))
            guard !Task.isCancelled else { return }
            self?.finish(.failure(AIOAuthError.invalid("Sign-in timed out. Try again.")))
        }
        return try await withCheckedThrowingContinuation { ready = $0; listener.start(queue: .main) }
    }
    func wait() async throws -> URL {
        try await withTaskCancellationHandler {
            if let outcome { return try outcome.get() }
            return try await withCheckedThrowingContinuation { result = $0 }
        } onCancel: { Task { @MainActor in self.cancel() } }
    }
    func cancel(with error: Error = CancellationError()) { finish(.failure(error)) }
    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] chunk, _, complete, error in
            Task { @MainActor in
                guard let self else { return }
                let buffer = data + (chunk ?? Data())
                guard buffer.count <= 16_384, error == nil else { self.close(connection); return }
                guard let text = String(data: buffer, encoding: .utf8), text.contains("\r\n\r\n") else {
                    if !complete { self.receive(connection, data: buffer) } else { self.close(connection) }
                    return
                }
                let line = text.components(separatedBy: "\r\n").first?.split(separator: " ") ?? []
                var validURL: URL?
                if line.count == 3, line[0] == "GET", let base = self.redirect,
                   let url = URL(string: String(line[1]), relativeTo: base)?.absoluteURL,
                   url.scheme == base.scheme, url.host == base.host, url.port == base.port, url.path == base.path {
                    let fields = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                    if fields.filter({ $0.name == "state" }).count == 1, fields.first(where: { $0.name == "state" })?.value == self.state { validURL = url }
                }
                let body = validURL == nil ? "Invalid callback." : "Sign-in received. You can close this tab and return to Bend."
                let response = "HTTP/1.1 \(validURL == nil ? "400 Bad Request" : "200 OK")\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
                let accepted = validURL
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                    Task { @MainActor in
                        self.close(connection)
                        if let accepted { self.finish(.success(accepted)) }
                    }
                })
            }
        }
    }
    private func close(_ connection: NWConnection) {
        connectionTimeouts.removeValue(forKey: ObjectIdentifier(connection))?.cancel()
        connections.removeAll { $0 === connection }
        connection.cancel()
    }
    private func finish(_ value: Result<URL, Error>) {
        guard outcome == nil else { return }
        outcome = value; listener?.cancel(); listener = nil; timeout?.cancel(); timeout = nil
        for connection in connections { close(connection) }
        if let ready { ready.resume(with: value); self.ready = nil }
        if let result { result.resume(with: value); self.result = nil }
    }
}

// Refresh credentials at each request, including agent tool follow-ups. Never redirect credentials.
struct AIAccountTransport: HTTPTransport {
    let base: any HTTPTransport
    let token: @Sendable () async throws -> String
    let host: String
    let team: String?
    func send(_ request: URLRequest) -> AsyncThrowingStream<HTTPEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard request.url?.scheme == "https", request.url?.host == host else {
                        throw AIOAuthError.invalid("Refused to send account credentials to an unexpected host.")
                    }
                    var authorized = request
                    authorized.setValue("Bearer " + (try await token()), forHTTPHeaderField: "Authorization")
                    if let team, !team.isEmpty { authorized.setValue(team, forHTTPHeaderField: "x-vercel-ai-gateway-team") }
                    for try await event in base.send(authorized) { try Task.checkCancellation(); continuation.yield(event) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
