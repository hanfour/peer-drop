import XCTest
@testable import webterm

final class AuthGateTests: XCTestCase {
    let secret = Data("server-secret-32-bytes-or-more!!".utf8)

    func test_passwordMode_validCookieAllows() {
        let cookie = SessionToken.issue(subject: "owner", idleTTL: 3600, secret: secret)
        let d = AuthGate.decide(mode: .password(secret: secret),
                                cookie: cookie, cfJWTValidEmail: nil, origin: "https://t.example.com",
                                expectedHost: "t.example.com")
        XCTAssertEqual(d, .allow)
    }
    func test_passwordMode_missingCookieDenies() {
        let d = AuthGate.decide(mode: .password(secret: secret),
                                cookie: nil, cfJWTValidEmail: nil, origin: "https://t.example.com",
                                expectedHost: "t.example.com")
        XCTAssertEqual(d, .denyUnauthorized)
    }
    func test_cloudflareMode_validatedEmailAllows() {
        let d = AuthGate.decide(mode: .cloudflare,
                                cookie: nil, cfJWTValidEmail: "owner@example.com",
                                origin: "https://t.example.com", expectedHost: "t.example.com")
        XCTAssertEqual(d, .allow)
    }
    func test_badOriginDenies() {
        let cookie = SessionToken.issue(subject: "owner", idleTTL: 3600, secret: secret)
        let d = AuthGate.decide(mode: .password(secret: secret),
                                cookie: cookie, cfJWTValidEmail: nil, origin: "https://evil.example.com",
                                expectedHost: "t.example.com")
        XCTAssertEqual(d, .denyForbidden)
    }
}
