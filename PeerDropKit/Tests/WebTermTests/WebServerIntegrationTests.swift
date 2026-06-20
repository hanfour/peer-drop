import XCTest
import HTTPTypes
import Hummingbird
import HummingbirdTesting
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
}
