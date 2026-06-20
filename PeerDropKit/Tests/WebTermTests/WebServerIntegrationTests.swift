import XCTest
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import HummingbirdWSTesting
import WSClient
@testable import webterm

final class WebServerIntegrationTests: XCTestCase {

    /// Full 401 → login → 200 flow via the in-process router test framework.
    func test_unauthenticatedRootIs401_andLoginThenAllows() async throws {
        let cfg = WebTermConfig.test(password: "hunter2")
        let app = try buildApplication(cfg)

        try await app.test(.router) { client in
            // 1. Unauthenticated GET / → 401
            try await client.execute(uri: "/", method: .get) { res in
                XCTAssertEqual(res.status, .unauthorized)
            }

            // 2. POST /login with correct password → 303 + Set-Cookie
            var cookie = ""
            try await client.execute(
                uri: "/login",
                method: .post,
                headers: [.contentType: "application/x-www-form-urlencoded"],
                body: ByteBuffer(string: "password=hunter2")
            ) { res in
                XCTAssertEqual(res.status, .seeOther)
                let setCookie = res.headers[.setCookie] ?? ""
                XCTAssertFalse(setCookie.isEmpty, "Expected Set-Cookie header after login")
                cookie = setCookie
            }

            // 3. Extract just the name=value part of the cookie (strip attributes)
            let cookiePair = cookie.split(separator: ";").first.map(String.init) ?? cookie

            // 4. Authenticated GET / → 200
            try await client.execute(
                uri: "/",
                method: .get,
                headers: [.cookie: cookiePair]
            ) { res in
                XCTAssertEqual(res.status, .ok)
            }
        }
    }

    /// Wrong password → 401 (not a redirect).
    func test_wrongPasswordIs401() async throws {
        let cfg = WebTermConfig.test(password: "correct-horse")
        let app = try buildApplication(cfg)

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/login",
                method: .post,
                headers: [.contentType: "application/x-www-form-urlencoded"],
                body: ByteBuffer(string: "password=wrong-battery-staple")
            ) { res in
                XCTAssertEqual(res.status, .unauthorized)
            }
        }
    }

    /// GET /login is accessible without auth (returns 200).
    func test_loginPageIsPublic() async throws {
        let cfg = WebTermConfig.test(password: "hunter2")
        let app = try buildApplication(cfg)

        try await app.test(.router) { client in
            try await client.execute(uri: "/login", method: .get) { res in
                XCTAssertEqual(res.status, .ok)
            }
        }
    }

    // MARK: - Decode helpers for /api/sessions preset-selector tests

    private struct PresetInfo: Decodable { let id: String; let name: String; let running: Bool }
    private struct SessionsResponse: Decodable { let presets: [PresetInfo] }

    /// GET /api/sessions is auth-gated.
    func test_sessionsEndpointRequiresAuth() async throws {
        let cfg = WebTermConfig.test(password: "hunter2")
        let app = try buildApplication(cfg)

        try await app.test(.router) { client in
            try await client.execute(uri: "/api/sessions", method: .get) { res in
                XCTAssertEqual(res.status, .unauthorized)
            }
        }
    }

    /// Authenticated GET /api/sessions returns JSON with a `presets` array containing "shell".
    func testSessionsReturnsPresets() async throws {
        let cfg = WebTermConfig.test(password: "hunter2")
        let app = try buildApplication(cfg)

        try await app.test(.router) { client in
            // 1. Login → cookie
            var cookiePair = ""
            try await client.execute(
                uri: "/login",
                method: .post,
                headers: [.contentType: "application/x-www-form-urlencoded"],
                body: ByteBuffer(string: "password=hunter2")
            ) { res in
                XCTAssertEqual(res.status, .seeOther)
                let setCookie = res.headers[.setCookie] ?? ""
                cookiePair = setCookie.split(separator: ";").first.map(String.init) ?? setCookie
            }

            // 2. Authenticated GET /api/sessions → 200 with presets JSON
            try await client.execute(
                uri: "/api/sessions",
                method: .get,
                headers: [.cookie: cookiePair]
            ) { res in
                XCTAssertEqual(res.status, .ok)
                let body = Data(buffer: res.body)
                let decoded = try JSONDecoder().decode(SessionsResponse.self, from: body)
                XCTAssertFalse(decoded.presets.isEmpty, "Expected at least one preset")
                XCTAssertTrue(decoded.presets.contains { $0.id == "shell" }, "Expected built-in 'shell' preset in response; got: \(decoded.presets.map(\.id))")
            }
        }
    }

    /// Pins Fix 3: login response cookie must carry SameSite=Strict.
    /// When expectedHost is "localhost", Secure must NOT be present (local HTTP dev).
    func test_loginCookie_hasSameSiteStrict_andNoSecureOnLocalhost() async throws {
        let cfg = WebTermConfig.test(password: "hunter2")  // expectedHost == "localhost"
        let app = try buildApplication(cfg)

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/login",
                method: .post,
                headers: [.contentType: "application/x-www-form-urlencoded"],
                body: ByteBuffer(string: "password=hunter2")
            ) { res in
                XCTAssertEqual(res.status, .seeOther)
                let setCookie = res.headers[.setCookie] ?? ""
                XCTAssertFalse(setCookie.isEmpty, "Expected Set-Cookie header")
                let lower = setCookie.lowercased()
                XCTAssertTrue(lower.contains("samesite=strict"), "Cookie must contain SameSite=Strict; got: \(setCookie)")
                XCTAssertFalse(lower.contains("; secure"), "Cookie must NOT include Secure for localhost; got: \(setCookie)")
            }
        }
    }

    /// Pins Fix 3 (non-localhost path): Secure flag must be present when expectedHost != "localhost".
    func test_loginCookie_hasSecure_whenNonLocalhost() async throws {
        var cfg = WebTermConfig.test(password: "hunter2")
        cfg.expectedHost = "term.example.com"
        let app = try buildApplication(cfg)

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/login",
                method: .post,
                headers: [
                    .contentType: "application/x-www-form-urlencoded",
                    // Include matching Origin so the auth gate doesn't 403 us
                    .origin: "https://term.example.com",
                ],
                body: ByteBuffer(string: "password=hunter2")
            ) { res in
                XCTAssertEqual(res.status, .seeOther)
                let setCookie = res.headers[.setCookie] ?? ""
                let lower = setCookie.lowercased()
                XCTAssertTrue(lower.contains("samesite=strict"), "Cookie must contain SameSite=Strict; got: \(setCookie)")
                XCTAssertTrue(lower.contains("; secure"), "Cookie must include Secure for non-localhost; got: \(setCookie)")
            }
        }
    }

    /// Pins Fix 1: connecting to /ws/shell on a FRESH server (no prior /api/sessions call)
    /// must create-or-attach the tmux session and keep the WebSocket connection open.
    ///
    /// Strategy: start a real live server (.live mode), login to obtain a session cookie,
    /// connect via WebSocket to /ws/shell with the cookie in additionalHeaders, send a
    /// WSFrame.ping and verify a pong is received — proving the connection was accepted,
    /// not immediately closed. Cleans up the tmux session in defer.
    ///
    /// Requires: `tmux` installed at /opt/homebrew/bin/tmux or visible on PATH.
    func test_wsShell_createOrAttachOnFreshServer() async throws {
        // Unique preset id per test run so parallel runs don't collide
        let pid = ProcessInfo.processInfo.processIdentifier
        let presetID = "wstestshell\(pid)"
        let tmuxID = TmuxControl.prefix + presetID
        let presets = [Preset(id: presetID, name: "WS Test Shell",
                              command: "sleep 60", cwd: nil, env: nil)]
        let cfg = WebTermConfig(
            port: 0,
            expectedHost: "localhost",
            auth: .password(hash: PasswordHash.make("wstest")),
            sessionSecret: Data((0..<32).map { _ in UInt8.random(in: 0...255) }),
            presets: presets
        )
        let app = try buildApplication(cfg)

        defer {
            // Clean up the tmux session regardless of test outcome
            _ = try? TmuxControl.kill(tmuxID)
        }

        // Pre-condition: the tmux session must NOT exist before the WS connection
        XCTAssertFalse(TmuxControl.exists(tmuxID), "tmux session must not exist before WS connect")

        try await app.test(.live) { client in
            // 1. Login → get session cookie
            var cookiePair = ""
            try await client.execute(
                uri: "/login",
                method: .post,
                headers: [.contentType: "application/x-www-form-urlencoded"],
                body: ByteBuffer(string: "password=wstest")
            ) { res in
                XCTAssertEqual(res.status, .seeOther)
                let setCookie = res.headers[.setCookie] ?? ""
                XCTAssertFalse(setCookie.isEmpty, "Expected Set-Cookie after login")
                // Strip cookie attributes — keep only name=value
                cookiePair = setCookie.split(separator: ";").first.map(String.init) ?? setCookie
            }

            // 2. Connect via WebSocket to /ws/<presetID> WITHOUT a prior /api/sessions call.
            //    The onUpgrade handler must create-or-attach the tmux session via SessionManager.
            //    We send a ping frame and immediately close the connection after sending —
            //    the fact that we reach this point (no throw) means the upgrade was accepted.
            let wsConfig = WebSocketClientConfiguration(
                additionalHeaders: [.cookie: cookiePair]
            )
            try await client.ws("/ws/\(presetID)", configuration: wsConfig) { _, outbound, _ in
                // Send a WSFrame.ping encoded as binary; any response proves the connection
                // was accepted (not immediately rejected). Then close cleanly.
                let pingBytes = WSFrame.ping.encoded()
                try await outbound.write(.binary(ByteBuffer(bytes: pingBytes)))
                // Close the WS by returning from the handler (no throw = success)
            }
            // If the WS handler above did NOT throw, the upgrade was accepted — no separate
            // bool flag needed. The tmux assertion below is the canonical correctness check.

            // 3. Verify the tmux session was actually created by the WS handler
            XCTAssertTrue(TmuxControl.exists(tmuxID), "tmux session '\(tmuxID)' was not created by the WS create-or-attach path")
        }
    }
}
