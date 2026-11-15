import Foundation
import Security
import Testing
import AI
@testable import Browse

// @lat: [[lat.md/tests/ai-tests#Account authorization validation]]
@Test func aiOAuthValidation() throws {
    let attempt = try AIOAuthAttempt()
    let redirect = URL(string: "http://127.0.0.1:17849/auth/callback")!
    let authorize = attempt.authorizationURL(provider: .openai, clientID: "dynamic_agent_client", redirect: redirect, hostID: "urn:uuid:test")
    let fields = Dictionary(uniqueKeysWithValues: URLComponents(url: authorize, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
    #expect(fields["code_challenge_method"] == "S256")
    #expect(fields["code_challenge"] == attempt.challenge)
    #expect(fields["ext_agent_host_id"] == "urn:uuid:test")
    #expect(fields["agent_name_hint"] == "Bend")
    #expect(fields["scope"]!.contains("chatgpt.tokens.use.direct"))
    func callback(_ query: String) -> URL { URL(string: redirect.absoluteString + "?" + query)! }
    let query = "state=\(attempt.state)&code=code&client_id=issued"
    #expect(try attempt.callback(callback(query), redirect: redirect, clientID: "dynamic_agent_client").clientID == "issued")
    #expect(throws: Error.self) { try attempt.callback(callback("state=wrong&code=x&client_id=issued"), redirect: redirect, clientID: "dynamic_agent_client") }
    #expect(throws: Error.self) { try attempt.callback(callback(query + "&code=duplicate"), redirect: redirect, clientID: "dynamic_agent_client") }
    #expect(throws: Error.self) { try attempt.callback(callback(query), redirect: redirect, clientID: "different") }
    #expect(throws: Error.self) { try attempt.callback(callback("state=\(attempt.state)&error=access_denied"), redirect: redirect, clientID: "issued") }
    #expect(throws: Error.self) { try attempt.callback(callback("state=\(attempt.state)&code=x"), redirect: redirect, clientID: "dynamic_agent_client") }

    let privateKey = try #require(SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, nil))
    let publicKey = try #require(SecKeyCopyPublicKey(privateKey))
    let encoded = try #require(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
    var offset = 0
    func tlv() -> Data {
        offset += 1
        var length = Int(encoded[offset]); offset += 1
        if length >= 128 {
            let bytes = length & 127; length = 0
            for _ in 0..<bytes { length = length * 256 + Int(encoded[offset]); offset += 1 }
        }
        let value = encoded.subdata(in: offset..<(offset + length)); offset += length
        return value
    }
    // Skip the sequence header, then read its modulus and exponent.
    offset = encoded[1] >= 128 ? 2 + Int(encoded[1] & 127) : 2
    let n = tlv(); let e = tlv()
    let jwks = try JSONSerialization.data(withJSONObject: ["keys": [["kty": "RSA", "kid": "test", "n": n.oauthBase64, "e": e.oauthBase64]]])
    let now = Date()
    let claims: [String: Any] = ["iss": "https://auth.openai.com", "aud": "issued", "sub": "subject", "nonce": attempt.nonce, "exp": now.timeIntervalSince1970 + 120, "email": "test@example.com"]
    func signed(_ claims: [String: Any]) throws -> String {
        let header = try JSONSerialization.data(withJSONObject: ["alg": "RS256", "kid": "test"]).oauthBase64
        let body = try JSONSerialization.data(withJSONObject: claims).oauthBase64
        let input = header + "." + body
        let signature = try #require(SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, Data(input.utf8) as CFData, nil)) as Data
        return input + "." + signature.oauthBase64
    }
    let token = try signed(claims)
    #expect(try OAuthIdentity.verify(token, jwks: jwks, issuer: "https://auth.openai.com", audience: "issued", nonce: attempt.nonce).email == "test@example.com")
    #expect(throws: Error.self) { try OAuthIdentity.verify(token, jwks: jwks, issuer: "https://vercel.com", audience: "issued", nonce: attempt.nonce) }
    #expect(throws: Error.self) { try OAuthIdentity.verify(token, jwks: jwks, issuer: "https://auth.openai.com", audience: "other", nonce: attempt.nonce) }
    #expect(throws: Error.self) { try OAuthIdentity.verify(token, jwks: jwks, issuer: "https://auth.openai.com", audience: "issued", nonce: "wrong") }
    #expect(throws: Error.self) { try OAuthIdentity.verify(token, jwks: jwks, issuer: "https://auth.openai.com", audience: "issued", nonce: attempt.nonce, now: now.addingTimeInterval(180)) }
    let pieces = token.split(separator: ".")
    let tampered = String(pieces[0]) + "." + Data("{}".utf8).oauthBase64 + "." + pieces[2]
    #expect(throws: Error.self) { try OAuthIdentity.verify(tampered, jwks: jwks, issuer: "https://auth.openai.com", audience: "issued", nonce: attempt.nonce) }
}

@MainActor private final class OAuthMemoryStore: AICredentialStore {
    var value: String?
    func read() throws -> String? { value }
    func save(_ value: String) throws { self.value = value }
    func delete() throws { value = nil }
}
private actor OAuthRequests {
    var values: [URLRequest] = []
    func append(_ request: URLRequest) { values.append(request) }
}
private struct OAuthFixture: HTTPTransport {
    let requests: OAuthRequests
    var denyScopes = false
    var failRevocation = false
    func send(_ request: URLRequest) -> AsyncThrowingStream<HTTPEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await requests.append(request)
                try? await Task.sleep(for: .milliseconds(20))
                if request.url!.path == "/v1/models" {
                    continuation.yield(.response(status: 200))
                    let body = request.url?.host == "api.openai.com"
                        ? #"{"models":[{"slug":"gpt-6-astra","display_name":"Astra","visibility":"list"},{"slug":"hidden","display_name":"Hidden","visibility":"hide"}]}"#
                        : #"{"data":[{"id":"openai/gpt-6-astra","name":"Astra","type":"language","tags":["tool-use"]}]}"#
                    continuation.yield(.data(Data(body.utf8)))
                } else if request.url!.path == "/v1/responses" {
                    continuation.yield(.response(status: 200))
                    continuation.yield(.data(Data("data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[]}}\n\n".utf8)))
                } else if request.url!.path.contains("revoke") {
                    continuation.yield(.response(status: failRevocation ? 503 : 200))
                } else {
                    continuation.yield(.response(status: 200))
                    let scopes = denyScopes ? "openid" : "chatgpt.tokens.use.direct openid"
                    continuation.yield(.data(Data("""
                    {"access_token":"new-access","refresh_token":"new-refresh","token_type":"Bearer","expires_in":3600,"scope":"\(scopes)"}
                    """.utf8)))
                }
                continuation.finish()
            }
        }
    }
}

// @lat: [[lat.md/tests/ai-tests#Account refresh and logout]]
@Test @MainActor func aiOAuthLifecycle() async throws {
    let store = OAuthMemoryStore()
    let old = AIAccountSession(clientID: "issued", subject: "subject", email: "test@example.com", accessToken: "old-access", refreshToken: "old-refresh", idToken: "old-id", scopes: "chatgpt.tokens.use.direct", expiresAt: .distantPast)
    store.value = String(decoding: try JSONEncoder().encode(["openai": old]), as: UTF8.self)
    let requests = OAuthRequests()
    let accounts = AIOAuthAccounts(storage: store, transport: OAuthFixture(requests: requests))
    try await accounts.restore()
    async let first = accounts.accessToken(.openai)
    async let second = accounts.accessToken(.openai)
    let tokens = try await [first, second]
    #expect(tokens == ["new-access", "new-access"])
    #expect(await requests.values.count == 1)
    let saved = try JSONDecoder().decode([String: AIAccountSession].self, from: Data(try #require(store.value).utf8))
    #expect(saved["openai"]?.refreshToken == "new-refresh")
    #expect(saved["openai"]?.clientID == "issued")
    #expect(try await accounts.logout(.openai))
    #expect(accounts.session(.openai)?.signedIn == false)
    #expect(accounts.session(.openai)?.idToken == "")
    #expect(accounts.session(.openai)?.clientID == "issued")
    await #expect(throws: Error.self) { try await accounts.accessToken(.openai) }
    let logout = try #require(await requests.values.last)
    #expect(String(decoding: logout.httpBody!, as: UTF8.self).contains("token=new-refresh"))

    // Denied plan permission must never replace the saved token set.
    store.value = String(decoding: try JSONEncoder().encode(["openai": old]), as: UTF8.self)
    let denied = AIOAuthAccounts(storage: store, transport: OAuthFixture(requests: OAuthRequests(), denyScopes: true))
    try await denied.restore()
    await #expect(throws: Error.self) { try await denied.accessToken(.openai) }
    #expect(denied.session(.openai)?.accessToken == "old-access")
    let offline = AIOAuthAccounts(storage: store, transport: OAuthFixture(requests: OAuthRequests(), failRevocation: true))
    try await offline.restore()
    #expect(try await offline.logout(.openai) == false)
    #expect(offline.session(.openai)?.signedIn == false)

    // An in-flight refresh cannot resurrect a logged-out account.
    store.value = String(decoding: try JSONEncoder().encode(["openai": old]), as: UTF8.self)
    let race = AIOAuthAccounts(storage: store, transport: OAuthFixture(requests: OAuthRequests()))
    try await race.restore()
    let refresh = Task { try await race.accessToken(.openai) }
    try await Task.sleep(for: .milliseconds(5))
    _ = try await race.logout(.openai)
    _ = try? await refresh.value
    #expect(race.session(.openai)?.signedIn == false)
}

// @lat: [[lat.md/tests/ai-tests#Loopback sign-in callback]]
@Test @MainActor func aiOAuthLoopback() async throws {
    let listener = OAuthLoopback()
    let redirect = try await listener.start(port: 0, state: "expected")
    defer { listener.cancel() }
    let session = URLSession(configuration: .ephemeral)
    let (_, rejected) = try await session.data(from: URL(string: redirect.absoluteString + "?state=wrong&code=x")!)
    #expect((rejected as? HTTPURLResponse)?.statusCode == 400)
    let valid = URL(string: redirect.absoluteString + "?state=expected&code=x&client_id=issued")!
    let (_, accepted) = try await session.data(from: valid)
    #expect((accepted as? HTTPURLResponse)?.statusCode == 200)
    #expect(try await listener.wait() == valid)
    let cancelled = OAuthLoopback()
    _ = try await cancelled.start(port: 0, state: "cancel")
    cancelled.cancel()
    await #expect(throws: CancellationError.self) { try await cancelled.wait() }
}

// @lat: [[lat.md/tests/ai-tests#Malformed loopback connections]]
@Test @MainActor func aiOAuthMalformedConnections() async throws {
    let listener = OAuthLoopback()
    let redirect = try await listener.start(port: 0, state: "expected")
    defer { listener.cancel() }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 2
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    for _ in 0..<12 {
        var request = URLRequest(url: redirect)
        request.setValue(String(repeating: "x", count: 20000), forHTTPHeaderField: "X-Oversized")
        _ = try? await session.data(for: request)
    }
    let valid = URL(string: redirect.absoluteString + "?state=expected&code=x&client_id=issued")!
    let (_, response) = try await session.data(from: valid)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    #expect(try await listener.wait() == valid)
}

// @lat: [[lat.md/tests/ai-tests#Account request routing]]
@Test func aiOAuthRouting() async throws {
    let requests = OAuthRequests()
    let transport = AIAccountTransport(base: OAuthFixture(requests: requests), token: { "oauth-access" }, host: "ai-gateway.vercel.sh", team: "my-team")
    var request = URLRequest(url: URL(string: "https://ai-gateway.vercel.sh/v1/responses")!)
    request.setValue("Bearer placeholder", forHTTPHeaderField: "Authorization")
    for try await _ in transport.send(request) {}
    let sent = try #require(await requests.values.first)
    #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer oauth-access")
    #expect(sent.value(forHTTPHeaderField: "x-vercel-ai-gateway-team") == "my-team")
    request.url = URL(string: "https://example.com/v1/responses")!
    await #expect(throws: Error.self) { for try await _ in transport.send(request) {} }
    #expect(await requests.values.count == 1)
}

// @lat: [[lat.md/tests/ai-tests#Account selection and models]]
@Test @MainActor func aiOAuthAccountSelection() async throws {
    let domain = "AccountSelection-\(UUID())"
    let defaults = UserDefaults(suiteName: domain)!
    defer { defaults.removePersistentDomain(forName: domain) }
    defaults.set("openai", forKey: "ai.connection")
    let saved = AIAccountSession(clientID: "issued", subject: "subject", email: "test@example.com",
                                 accessToken: "access", refreshToken: "refresh", scopes: "chatgpt.tokens.use.direct",
                                 expiresAt: Date().addingTimeInterval(3600))
    let storage = OAuthMemoryStore()
    storage.value = String(decoding: try JSONEncoder().encode(["openai": saved]), as: UTF8.self)
    let requests = OAuthRequests()
    let transport = OAuthFixture(requests: requests)
    let accounts = AIOAuthAccounts(storage: storage, transport: transport, defaults: defaults)
    let legacy = OAuthMemoryStore()
    let settings = AISettings(transport: transport, credential: legacy, defaults: defaults, accounts: accounts)
    await settings.restore()
    #expect(settings.connected)
    #expect(settings.models.map(\.id) == ["gpt-6-astra"])
    #expect(settings.accountEmails["openai"] == "test@example.com")
    let discoveryCount = await requests.values.count
    await settings.restore()
    #expect(await requests.values.count == discoveryCount) // Opening chat reuses the catalog.
    let model = try settings.model(settings.modelID)
    let response = model.provider.stream(.init(modelID: model.id, messages: [.user("test")]))
    for try await _ in response {}
    let request = try #require(await requests.values.last)
    #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access")
    let body = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as! [String: Any]
    #expect(body["model"] as? String == "gpt-6-astra")
    #expect(body["store"] as? Bool == false)
    await settings.logout(.openai)
    #expect(!settings.connected && settings.models.isEmpty)
    #expect(throws: Error.self) { try settings.model("gpt-6-astra") }
    await settings.connect("legacy-key")
    #expect(settings.activeConnection == "gateway")
    #expect(settings.modelID == "openai/gpt-6-astra")
}

// @lat: [[lat.md/tests/ai-tests#Test credential isolation]]
@Test @MainActor func aiTestCredentialIsolation() async throws {
    #if BEND_TESTING
    let service = "BendCredentialFixture-\(UUID())"
    let first = GatewayCredential(service: service)
    let same = GatewayCredential(service: service)
    let other = GatewayCredential(service: service + ".other")
    defer { try? first.delete(); try? other.delete() }
    #expect(try await first.readAsync() == nil)
    try first.save("synthetic-key")
    #expect(try same.read() == "synthetic-key")
    #expect(try await other.readAsync() == nil)
    try same.delete()
    #expect(try first.read() == nil)
    let domain = "AIDefaultCredentialFixture-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: domain))
    defer { defaults.removePersistentDomain(forName: domain) }
    let settings = AISettings(defaults: defaults)
    await settings.restore()
    #expect(!settings.connected && settings.error == nil)
    #else
    Issue.record("Run native tests through scripts/test.sh to isolate Keychain access.")
    #endif
}
