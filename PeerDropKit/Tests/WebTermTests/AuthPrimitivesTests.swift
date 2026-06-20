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
        let token = SessionToken.issue(subject: "owner", ttl: 3600, secret: secret)
        XCTAssertEqual(SessionToken.verify(token, secret: secret), "owner")
        XCTAssertNil(SessionToken.verify(token, secret: Data("different".utf8)))
    }
    func test_sessionTokenExpired() {
        let secret = Data("server-secret-32-bytes-or-more!!".utf8)
        let token = SessionToken.issue(subject: "owner", ttl: -1, secret: secret)
        XCTAssertNil(SessionToken.verify(token, secret: secret))
    }
}
