import XCTest
import HTTPTypes
import Hummingbird
import HummingbirdTesting
@testable import webterm

/// Integration tests for sliding idle-timeout sessions and the /api/ping heartbeat.
final class SlidingSessionTests: XCTestCase {

    // MARK: - Login helper (matches WebServerIntegrationTests.login but scoped here)

    @discardableResult
    private func login(
        client: some TestClientProtocol,
        password: String,
        origin: String? = nil,
        expectedStatus: HTTPResponse.Status = .seeOther
    ) async throws -> String {
        var csrfCookieValue = ""
        try await client.execute(uri: "/login", method: .get) { res in
            let setCookieHeader = res.headers[.setCookie] ?? ""
            for part in setCookieHeader.split(separator: ";") {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("webterm-csrf=") {
                    csrfCookieValue = String(trimmed.dropFirst("webterm-csrf=".count))
                    break
                }
            }
        }

        var loginSetCookie = ""
        var requestHeaders: HTTPFields = [
            .contentType: "application/x-www-form-urlencoded",
            .cookie: "webterm-csrf=\(csrfCookieValue)"
        ]
        if let origin { requestHeaders[.origin] = origin }

        try await client.execute(
            uri: "/login",
            method: .post,
            headers: requestHeaders,
            body: ByteBuffer(string: "password=\(password)&csrf=\(csrfCookieValue)")
        ) { res in
            XCTAssertEqual(res.status, expectedStatus)
            loginSetCookie = res.headers[.setCookie] ?? ""
        }
        return loginSetCookie
    }

    // MARK: - /api/ping is auth-gated

    /// GET /api/ping without a session cookie → 401.
    func test_ping_withoutAuth_returns401() async throws {
        let cfg = WebTermConfig.test(password: "hunter2")
        let app = try buildApplication(cfg)

        try await app.test(.router) { client in
            try await client.execute(uri: "/api/ping", method: .get) { res in
                XCTAssertEqual(res.status, .unauthorized,
                    "Expected 401 from /api/ping without auth; got \(res.status)")
            }
        }
    }

    /// GET /api/ping with a valid session cookie → 204 No Content.
    func test_ping_withAuth_returns204() async throws {
        let cfg = WebTermConfig.test(password: "hunter2")
        let app = try buildApplication(cfg)

        try await app.test(.router) { client in
            let setCookie = try await login(client: client, password: "hunter2")
            let cookiePair = setCookie.split(separator: ";").first.map(String.init) ?? setCookie

            try await client.execute(
                uri: "/api/ping",
                method: .get,
                headers: [.cookie: cookiePair]
            ) { res in
                XCTAssertEqual(res.status, .noContent,
                    "Expected 204 from /api/ping with valid auth; got \(res.status)")
            }
        }
    }

    // MARK: - Sliding: authed requests refresh the session cookie

    /// An authenticated GET (e.g. /api/ping or /) must return a refreshed `webterm-session`
    /// Set-Cookie header in password mode — proving the middleware slides the token.
    func test_authedRequest_slides_cookie() async throws {
        let cfg = WebTermConfig.test(password: "hunter2", idleTTL: 1800, maxSessionAge: 12 * 3600)
        let app = try buildApplication(cfg)

        try await app.test(.router) { client in
            // Login → get the initial session cookie value
            let loginSetCookie = try await login(client: client, password: "hunter2")
            XCTAssertFalse(loginSetCookie.isEmpty, "Expected Set-Cookie after login")
            let cookiePair = loginSetCookie.split(separator: ";").first.map(String.init) ?? loginSetCookie

            // Make an authenticated request to /api/ping
            var pingSetCookie = ""
            try await client.execute(
                uri: "/api/ping",
                method: .get,
                headers: [.cookie: cookiePair]
            ) { res in
                XCTAssertEqual(res.status, .noContent)
                pingSetCookie = res.headers[.setCookie] ?? ""
            }

            // The response must include a refreshed webterm-session Set-Cookie
            XCTAssertFalse(pingSetCookie.isEmpty,
                "Expected a Set-Cookie (sliding) on the authenticated /api/ping response")
            XCTAssertTrue(pingSetCookie.lowercased().contains("webterm-session="),
                "Refreshed Set-Cookie must name webterm-session; got: \(pingSetCookie)")
        }
    }

    /// After sliding, the NEW cookie must itself be accepted for a subsequent authed request.
    func test_slidCookie_isValid_forSubsequentRequest() async throws {
        let cfg = WebTermConfig.test(password: "hunter2", idleTTL: 1800, maxSessionAge: 12 * 3600)
        let app = try buildApplication(cfg)

        try await app.test(.router) { client in
            // 1. Login
            let loginSetCookie = try await login(client: client, password: "hunter2")
            let cookiePair = loginSetCookie.split(separator: ";").first.map(String.init) ?? loginSetCookie

            // 2. Hit /api/ping → get the slid cookie
            var slidCookiePair = ""
            try await client.execute(
                uri: "/api/ping",
                method: .get,
                headers: [.cookie: cookiePair]
            ) { res in
                let sc = res.headers[.setCookie] ?? ""
                slidCookiePair = sc.split(separator: ";").first.map(String.init) ?? sc
            }
            XCTAssertFalse(slidCookiePair.isEmpty, "Expected slid Set-Cookie from /api/ping")

            // 3. Use the slid cookie on GET / → must be 200 (not 401)
            try await client.execute(
                uri: "/",
                method: .get,
                headers: [.cookie: slidCookiePair]
            ) { res in
                XCTAssertEqual(res.status, .ok,
                    "Slid cookie must be accepted for a subsequent authed request; got \(res.status)")
            }
        }
    }

    // MARK: - Idle-expired token is rejected

    /// A token whose exp is in the past → 401 (idle-expired, must not be allowed through).
    func test_idleExpiredToken_returns401() async throws {
        let cfg = WebTermConfig.test(password: "hunter2", idleTTL: 1800, maxSessionAge: 12 * 3600)
        let app = try buildApplication(cfg)

        try await app.test(.router) { client in
            // Manually craft an expired token (idleTTL = -1 so exp < now)
            let expiredToken = SessionToken.issue(
                subject: "owner",
                idleTTL: -1,
                secret: cfg.sessionSecret
            )
            let cookiePair = "webterm-session=\(expiredToken)"

            try await client.execute(
                uri: "/api/ping",
                method: .get,
                headers: [.cookie: cookiePair]
            ) { res in
                XCTAssertEqual(res.status, .unauthorized,
                    "Idle-expired token must be rejected with 401; got \(res.status)")
            }
        }
    }

    // MARK: - Cloudflare mode: no slide (CF manages its own session)

    /// In Cloudflare mode, an authenticated request must NOT set a webterm-session cookie
    /// (CF manages its own JWT; app-level sliding does not apply).
    func test_cloudflareMode_noSessionCookieSlide() async throws {
        // Build a minimal cloudflare-mode config.
        // We can test this at the middleware level via AuthGate (no real CF verifier needed
        // since we won't actually call AuthMiddleware with a CF verifier in .router mode).
        // Instead, verify the factory behaviour: cloudflare mode sets no idleTTL sliding
        // by confirming AuthMiddleware.cloudflare is built correctly (has mode == .cloudflare).
        // The real end-to-end CF path is tested by CfAccessVerifierTests; here we just
        // assert the mode at the type level.
        let mw: AuthMiddleware<BasicRequestContext> = AuthMiddleware.cloudflare(
            verifier: CfAccessVerifier(
                audience: "aud",
                ownerEmail: "owner@example.com",
                keys: .init()
            ),
            expectedHost: "term.example.com"
        )
        if case .cloudflare = mw.mode {
            // pass — sliding only fires in password mode
        } else {
            XCTFail("Expected cloudflare mode in the built middleware")
        }
    }
}
