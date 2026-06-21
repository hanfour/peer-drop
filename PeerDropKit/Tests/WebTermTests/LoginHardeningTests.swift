import XCTest
import HTTPTypes
import Hummingbird
import HummingbirdTesting
@testable import webterm

/// Tests for CSRF double-submit, global login rate-limit, and logout endpoint.
final class LoginHardeningTests: XCTestCase {

    // MARK: - CSRF tests

    /// POST /login with a missing csrf field → 403 (before password check).
    func test_csrf_missingField_returns403() async throws {
        let cfg = WebTermConfig.test(password: "hunter2")
        let app = try buildApplication(cfg)

        try await app.test(.router) { client in
            // First obtain a valid CSRF cookie by doing GET /login
            var csrfCookieValue = ""
            try await client.execute(uri: "/login", method: .get) { res in
                let header = res.headers[.setCookie] ?? ""
                for part in header.split(separator: ";") {
                    let t = part.trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("webterm-csrf=") {
                        csrfCookieValue = String(t.dropFirst("webterm-csrf=".count))
                        break
                    }
                }
            }

            // POST without the csrf field (body has only password)
            try await client.execute(
                uri: "/login",
                method: .post,
                headers: [
                    .contentType: "application/x-www-form-urlencoded",
                    .cookie: "webterm-csrf=\(csrfCookieValue)",
                ],
                body: ByteBuffer(string: "password=hunter2")
            ) { res in
                XCTAssertEqual(res.status, .forbidden,
                    "Expected 403 when csrf field is absent; got \(res.status)")
            }
        }
    }

    /// POST /login with a wrong csrf field → 403.
    func test_csrf_wrongFieldValue_returns403() async throws {
        let cfg = WebTermConfig.test(password: "hunter2")
        let app = try buildApplication(cfg)

        try await app.test(.router) { client in
            var csrfCookieValue = ""
            try await client.execute(uri: "/login", method: .get) { res in
                let header = res.headers[.setCookie] ?? ""
                for part in header.split(separator: ";") {
                    let t = part.trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("webterm-csrf=") {
                        csrfCookieValue = String(t.dropFirst("webterm-csrf=".count))
                        break
                    }
                }
            }

            // Send a DIFFERENT token in the form field
            try await client.execute(
                uri: "/login",
                method: .post,
                headers: [
                    .contentType: "application/x-www-form-urlencoded",
                    .cookie: "webterm-csrf=\(csrfCookieValue)",
                ],
                body: ByteBuffer(string: "password=hunter2&csrf=deadbeefdeadbeefdeadbeefdeadbeef")
            ) { res in
                XCTAssertEqual(res.status, .forbidden,
                    "Expected 403 when csrf field doesn't match cookie; got \(res.status)")
            }
        }
    }

    /// POST /login with no csrf cookie at all → 403.
    func test_csrf_missingCookie_returns403() async throws {
        let cfg = WebTermConfig.test(password: "hunter2")
        let app = try buildApplication(cfg)

        try await app.test(.router) { client in
            // No GET /login first — no cookie is set
            try await client.execute(
                uri: "/login",
                method: .post,
                headers: [.contentType: "application/x-www-form-urlencoded"],
                body: ByteBuffer(string: "password=hunter2&csrf=deadbeef")
            ) { res in
                XCTAssertEqual(res.status, .forbidden,
                    "Expected 403 when csrf cookie is absent; got \(res.status)")
            }
        }
    }

    /// GET /login response embeds a csrf hidden field matching the cookie value.
    func test_csrf_loginPageEmbedsCsrfToken() async throws {
        let cfg = WebTermConfig.test(password: "hunter2")
        let app = try buildApplication(cfg)

        try await app.test(.router) { client in
            var csrfCookieValue = ""
            var htmlBody = ""

            try await client.execute(uri: "/login", method: .get) { res in
                XCTAssertEqual(res.status, .ok)
                htmlBody = String(buffer: res.body)
                let header = res.headers[.setCookie] ?? ""
                for part in header.split(separator: ";") {
                    let t = part.trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("webterm-csrf=") {
                        csrfCookieValue = String(t.dropFirst("webterm-csrf=".count))
                        break
                    }
                }
            }

            XCTAssertFalse(csrfCookieValue.isEmpty, "Expected webterm-csrf cookie on GET /login")
            // The HTML must embed the token as a hidden input value
            XCTAssertTrue(htmlBody.contains("value=\"\(csrfCookieValue)\""),
                "Expected CSRF token embedded in login form; token=\(csrfCookieValue)")
        }
    }

    // MARK: - Rate-limit unit tests (injected clock, no sleeps)

    /// 5 failures within window → isLimited() == true.
    func test_rateLimiter_5FailuresWithinWindow_isLimited() async {
        let limiter = LoginRateLimiter(maxFailures: 5, window: 60, clock: { Date() })
        for _ in 0..<5 { await limiter.recordFailure() }
        let limited = await limiter.isLimited()
        XCTAssertTrue(limited, "Expected limiter to be active after 5 failures")
    }

    /// 4 failures (one below threshold) → isLimited() == false.
    func test_rateLimiter_4Failures_notLimited() async {
        let limiter = LoginRateLimiter(maxFailures: 5, window: 60, clock: { Date() })
        for _ in 0..<4 { await limiter.recordFailure() }
        let limited = await limiter.isLimited()
        XCTAssertFalse(limited, "Expected limiter to be inactive after only 4 failures")
    }

    /// Failures outside the window (clock advanced) → isLimited() == false.
    func test_rateLimiter_failuresOlderThanWindow_notLimited() async {
        // Simulate: 5 failures at t=0, then time advances by 61 seconds.
        var t = Date(timeIntervalSince1970: 1_000_000)
        let limiter = LoginRateLimiter(maxFailures: 5, window: 60, clock: { t })

        for _ in 0..<5 { await limiter.recordFailure() }

        // Advance clock past the window
        t = t.addingTimeInterval(61)
        let limited = await limiter.isLimited()
        XCTAssertFalse(limited, "Expected limiter to reset after window expires")
    }

    /// recordSuccess() clears the failure history.
    func test_rateLimiter_recordSuccess_clearsHistory() async {
        let limiter = LoginRateLimiter(maxFailures: 5, window: 60, clock: { Date() })
        for _ in 0..<5 { await limiter.recordFailure() }
        await limiter.recordSuccess()
        let limited = await limiter.isLimited()
        XCTAssertFalse(limited, "Expected limiter to be cleared after recordSuccess()")
    }

    // MARK: - Rate-limit integration test

    /// Submitting wrong passwords enough times eventually returns 429.
    func test_rateLimit_wrongPasswordRepeated_returns429() async throws {
        // Low threshold so the test runs quickly
        let limiter = LoginRateLimiter(maxFailures: 3, window: 60)
        let cfg = WebTermConfig.test(password: "correct")
        let app = try buildApplication(cfg, rateLimiter: limiter)

        try await app.test(.router) { client in
            // Exhaust 3 failures (each POST needs a fresh CSRF cookie)
            for i in 1...3 {
                // GET /login for a fresh CSRF token each round
                var csrfToken = ""
                try await client.execute(uri: "/login", method: .get) { res in
                    let header = res.headers[.setCookie] ?? ""
                    for part in header.split(separator: ";") {
                        let t = part.trimmingCharacters(in: .whitespaces)
                        if t.hasPrefix("webterm-csrf=") {
                            csrfToken = String(t.dropFirst("webterm-csrf=".count))
                            break
                        }
                    }
                }

                try await client.execute(
                    uri: "/login",
                    method: .post,
                    headers: [
                        .contentType: "application/x-www-form-urlencoded",
                        .cookie: "webterm-csrf=\(csrfToken)",
                    ],
                    body: ByteBuffer(string: "password=wrong&csrf=\(csrfToken)")
                ) { res in
                    // The first 3 attempts should be 401 (wrong password)
                    XCTAssertEqual(res.status, .unauthorized, "Attempt \(i) should be 401")
                }
            }

            // The 4th attempt should be 429 (rate limited — checked before password)
            var csrfToken = ""
            try await client.execute(uri: "/login", method: .get) { res in
                let header = res.headers[.setCookie] ?? ""
                for part in header.split(separator: ";") {
                    let t = part.trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("webterm-csrf=") {
                        csrfToken = String(t.dropFirst("webterm-csrf=".count))
                        break
                    }
                }
            }

            try await client.execute(
                uri: "/login",
                method: .post,
                headers: [
                    .contentType: "application/x-www-form-urlencoded",
                    .cookie: "webterm-csrf=\(csrfToken)",
                ],
                body: ByteBuffer(string: "password=correct&csrf=\(csrfToken)")
            ) { res in
                XCTAssertEqual(res.status, .tooManyRequests,
                    "Expected 429 after rate-limit exhaustion; got \(res.status)")
            }
        }
    }

    // MARK: - Logout tests

    /// POST /logout (with valid session) → 303 redirect to /login + Set-Cookie clearing the session.
    func test_logout_clearsSessionCookie() async throws {
        let cfg = WebTermConfig.test(password: "hunter2")
        let app = try buildApplication(cfg)

        try await app.test(.router) { client in
            // 1. Login to get a session cookie
            var csrfToken = ""
            try await client.execute(uri: "/login", method: .get) { res in
                let header = res.headers[.setCookie] ?? ""
                for part in header.split(separator: ";") {
                    let t = part.trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("webterm-csrf=") {
                        csrfToken = String(t.dropFirst("webterm-csrf=".count))
                        break
                    }
                }
            }

            var sessionCookiePair = ""
            try await client.execute(
                uri: "/login",
                method: .post,
                headers: [
                    .contentType: "application/x-www-form-urlencoded",
                    .cookie: "webterm-csrf=\(csrfToken)",
                ],
                body: ByteBuffer(string: "password=hunter2&csrf=\(csrfToken)")
            ) { res in
                XCTAssertEqual(res.status, .seeOther)
                let sc = res.headers[.setCookie] ?? ""
                sessionCookiePair = sc.split(separator: ";").first.map(String.init) ?? sc
            }

            XCTAssertFalse(sessionCookiePair.isEmpty, "Expected session cookie after login")

            // 2. POST /logout with the session cookie
            try await client.execute(
                uri: "/logout",
                method: .post,
                headers: [.cookie: sessionCookiePair]
            ) { res in
                XCTAssertEqual(res.status, .seeOther, "Expected 303 from /logout; got \(res.status)")

                // Location header must point to /login
                let location = res.headers[values: .location].first ?? ""
                XCTAssertEqual(location, "/login", "Expected redirect to /login; got \(location)")

                // Set-Cookie must clear webterm-session (maxAge=0 or "expires" in the past)
                let setCookie = res.headers[.setCookie] ?? ""
                XCTAssertTrue(setCookie.lowercased().contains("webterm-session="),
                    "Expected Set-Cookie for webterm-session in logout response; got: \(setCookie)")
                XCTAssertTrue(setCookie.lowercased().contains("max-age=0"),
                    "Expected max-age=0 in logout Set-Cookie to clear the cookie; got: \(setCookie)")
            }
        }
    }

    /// POST /logout without a session cookie → 401 (auth-gated).
    func test_logout_requiresAuth() async throws {
        let cfg = WebTermConfig.test(password: "hunter2")
        let app = try buildApplication(cfg)

        try await app.test(.router) { client in
            try await client.execute(uri: "/logout", method: .post) { res in
                XCTAssertEqual(res.status, .unauthorized,
                    "Expected 401 when accessing /logout without a session; got \(res.status)")
            }
        }
    }
}
