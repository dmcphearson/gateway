import Foundation
import Testing
@testable import AWS_CLI_Gateway

/// Records requests and replies with a canned response, or runs `onRequest`
/// to simulate another tool touching the token file mid-refresh.
final class FakeOIDC: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { _requests } }

    let status: Int
    let body: [String: Any]
    let error: Error?
    let onRequest: (@Sendable () -> Void)?

    init(status: Int = 200, body: [String: Any] = [:], error: Error? = nil, onRequest: (@Sendable () -> Void)? = nil) {
        self.status = status
        self.body = body
        self.error = error
        self.onRequest = onRequest
    }

    var transport: SSOTokenRefresher.Transport {
        { request in
            self.lock.withLock { self._requests.append(request) }
            self.onRequest?()
            if let error = self.error { throw error }
            let data = try JSONSerialization.data(withJSONObject: self.body)
            let response = HTTPURLResponse(url: request.url!, statusCode: self.status, httpVersion: nil, headerFields: nil)!
            return (data, response)
        }
    }
}

struct SSOTokenRefresherTests {
    let session = "example-session"
    let now = ISO8601DateFormatter().date(from: "2026-01-01T12:00:00Z")!
    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("sso-refresher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    @discardableResult
    func writeToken(expiresIn: TimeInterval, registrationExpiresIn: TimeInterval = 86_400 * 30,
                    refreshToken: String = "fake-refresh-1") throws -> URL {
        let token: [String: Any] = [
            "startUrl": "https://example.awsapps.com/start",
            "region": "eu-west-1",
            "accessToken": "fake-access-1",
            "expiresAt": iso(now.addingTimeInterval(expiresIn)),
            "clientId": "fake-client-id",
            "clientSecret": "fake-client-secret",
            "registrationExpiresAt": iso(now.addingTimeInterval(registrationExpiresIn)),
            "refreshToken": refreshToken,
        ]
        let file = SSOTokenRefresher(cacheDirectory: dir).tokenFile(forSession: session)
        try JSONSerialization.data(withJSONObject: token).write(to: file)
        return file
    }

    func readToken(_ file: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
    }

    @Test func tokenFileUsesSessionNameHash() {
        let file = SSOTokenRefresher(cacheDirectory: dir).tokenFile(forSession: "my-sso")
        // printf %s my-sso | shasum
        #expect(file.lastPathComponent == "0ad374308c5a4e22f723adf10145eafad7c4031c.json")
    }

    @Test func leavesTokenAloneOutsideRefreshWindow() async throws {
        try writeToken(expiresIn: 45 * 60)
        let oidc = FakeOIDC()
        let outcome = await SSOTokenRefresher(cacheDirectory: dir, transport: oidc.transport)
            .refreshIfNeeded(sessionName: session, now: now)
        #expect(outcome == .fresh)
        #expect(oidc.requests.isEmpty)
    }

    @Test func refreshesInsideWindowAndWritesBackInPlace() async throws {
        let file = try writeToken(expiresIn: 10 * 60)
        let oidc = FakeOIDC(body: ["accessToken": "fake-access-2", "expiresIn": 3600,
                                   "refreshToken": "fake-refresh-2", "tokenType": "Bearer"])
        let outcome = await SSOTokenRefresher(cacheDirectory: dir, transport: oidc.transport)
            .refreshIfNeeded(sessionName: session, now: now)

        #expect(outcome == .refreshed(expiresAt: now.addingTimeInterval(3600)))

        let request = try #require(oidc.requests.first)
        #expect(request.url?.absoluteString == "https://oidc.eu-west-1.amazonaws.com/token")
        #expect(request.httpMethod == "POST")
        let sent = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as! [String: String]
        #expect(sent == ["clientId": "fake-client-id", "clientSecret": "fake-client-secret",
                         "grantType": "refresh_token", "refreshToken": "fake-refresh-1"])

        let token = try readToken(file)
        #expect(token["accessToken"] as? String == "fake-access-2")
        #expect(token["refreshToken"] as? String == "fake-refresh-2")
        #expect(token["expiresAt"] as? String == "2026-01-01T13:00:00Z")
        // Fields the CLI and SDKs need are preserved.
        #expect(token["clientId"] as? String == "fake-client-id")
        #expect(token["startUrl"] as? String == "https://example.awsapps.com/start")
        #expect(token["registrationExpiresAt"] != nil)

        let perms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }

    @Test func refreshesExpiredToken() async throws {
        try writeToken(expiresIn: -2 * 3600)
        let oidc = FakeOIDC(body: ["accessToken": "fake-access-2", "expiresIn": 3600])
        let outcome = await SSOTokenRefresher(cacheDirectory: dir, transport: oidc.transport)
            .refreshIfNeeded(sessionName: session, now: now)
        #expect(outcome == .refreshed(expiresAt: now.addingTimeInterval(3600)))
    }

    @Test func keepsRefreshTokenWhenServerDoesNotRotateIt() async throws {
        let file = try writeToken(expiresIn: 5 * 60)
        let oidc = FakeOIDC(body: ["accessToken": "fake-access-2", "expiresIn": 3600])
        _ = await SSOTokenRefresher(cacheDirectory: dir, transport: oidc.transport)
            .refreshIfNeeded(sessionName: session, now: now)
        #expect(try readToken(file)["refreshToken"] as? String == "fake-refresh-1")
    }

    @Test func invalidGrantNeedsLogin() async throws {
        let file = try writeToken(expiresIn: 5 * 60)
        let oidc = FakeOIDC(status: 400, body: ["error": "invalid_grant", "error_description": "Invalid refresh token provided"])
        let outcome = await SSOTokenRefresher(cacheDirectory: dir, transport: oidc.transport)
            .refreshIfNeeded(sessionName: session, now: now)
        guard case .needsLogin = outcome else { Issue.record("expected needsLogin, got \(outcome)"); return }
        #expect(try readToken(file)["accessToken"] as? String == "fake-access-1")
    }

    @Test func invalidGrantAfterAnotherToolRotatedTokenIsNotALoginPrompt() async throws {
        let file = try writeToken(expiresIn: 5 * 60)
        let dir = self.dir, session = self.session, now = self.now
        // Simulates the CLI refreshing between our read and our request.
        let oidc = FakeOIDC(status: 400, body: ["error": "invalid_grant"], onRequest: {
            var token = try! JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
            token["refreshToken"] = "fake-refresh-from-cli"
            token["accessToken"] = "fake-access-from-cli"
            token["expiresAt"] = ISO8601DateFormatter().string(from: now.addingTimeInterval(3600))
            try! JSONSerialization.data(withJSONObject: token).write(to: SSOTokenRefresher(cacheDirectory: dir).tokenFile(forSession: session))
        })
        let outcome = await SSOTokenRefresher(cacheDirectory: dir, transport: oidc.transport)
            .refreshIfNeeded(sessionName: session, now: now)
        #expect(outcome == .alreadyRefreshed)
        #expect(try readToken(file)["accessToken"] as? String == "fake-access-from-cli")
    }

    @Test func expiredRegistrationNeedsLoginWithoutCallingOIDC() async throws {
        try writeToken(expiresIn: 5 * 60, registrationExpiresIn: -60)
        let oidc = FakeOIDC()
        let outcome = await SSOTokenRefresher(cacheDirectory: dir, transport: oidc.transport)
            .refreshIfNeeded(sessionName: session, now: now)
        guard case .needsLogin = outcome else { Issue.record("expected needsLogin, got \(outcome)"); return }
        #expect(oidc.requests.isEmpty)
    }

    @Test func missingTokenFileNeedsLogin() async throws {
        let outcome = await SSOTokenRefresher(cacheDirectory: dir, transport: FakeOIDC().transport)
            .refreshIfNeeded(sessionName: session, now: now)
        guard case .needsLogin = outcome else { Issue.record("expected needsLogin, got \(outcome)"); return }
    }

    @Test func networkErrorIsTransientAndLeavesFileUntouched() async throws {
        let file = try writeToken(expiresIn: 5 * 60)
        let before = try Data(contentsOf: file)
        let oidc = FakeOIDC(error: URLError(.notConnectedToInternet))
        let outcome = await SSOTokenRefresher(cacheDirectory: dir, transport: oidc.transport)
            .refreshIfNeeded(sessionName: session, now: now)
        guard case .failed = outcome else { Issue.record("expected failed, got \(outcome)"); return }
        #expect(try Data(contentsOf: file) == before)
    }

    @Test func serverErrorIsTransient() async throws {
        try writeToken(expiresIn: 5 * 60)
        let oidc = FakeOIDC(status: 500, body: ["error": "InternalServerException"])
        let outcome = await SSOTokenRefresher(cacheDirectory: dir, transport: oidc.transport)
            .refreshIfNeeded(sessionName: session, now: now)
        guard case .failed = outcome else { Issue.record("expected failed, got \(outcome)"); return }
    }
}
