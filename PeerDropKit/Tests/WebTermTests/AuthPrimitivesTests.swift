import XCTest
import Foundation
@testable import webterm

final class AuthPrimitivesTests: XCTestCase {
    func test_passwordHashVerifyRoundTrip() {
        let h = PasswordHash.make("hunter2")
        XCTAssertTrue(PasswordHash.verify("hunter2", against: h))
        XCTAssertFalse(PasswordHash.verify("wrong", against: h))
    }

    func test_sessionTokenSignVerify() {
        let secret = Data("server-secret-32-bytes-or-more!!".utf8)
        let token = SessionToken.issue(subject: "owner", idleTTL: 3600, secret: secret)
        XCTAssertEqual(SessionToken.verify(token, secret: secret, maxAge: 12 * 3600), "owner")
        XCTAssertNil(SessionToken.verify(token, secret: Data("different".utf8), maxAge: 12 * 3600))
    }

    func test_sessionTokenExpired() {
        let secret = Data("server-secret-32-bytes-or-more!!".utf8)
        // Issue a token with idleTTL = -1 so exp < now
        let token = SessionToken.issue(subject: "owner", idleTTL: -1, secret: secret)
        XCTAssertNil(SessionToken.verify(token, secret: secret, maxAge: 12 * 3600))
    }
}
