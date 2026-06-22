import XCTest
import Foundation
@testable import webterm

/// Unit tests for the sliding idle-timeout SessionToken (4-part format).
final class SessionTokenTests: XCTestCase {

    let secret = Data("session-secret-32-bytes-exactly!!".utf8)

    // MARK: - Basic round-trip

    func test_issue_verify_roundTrip() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let token = SessionToken.issue(subject: "owner", idleTTL: 3600, secret: secret, now: t0)
        // Verify at t0 + 1800 (well within idle window and maxAge)
        let subject = SessionToken.verify(token, secret: secret, maxAge: 12 * 3600,
                                          now: t0.addingTimeInterval(1800))
        XCTAssertEqual(subject, "owner")
    }

    func test_verify_wrongSecret_returnsNil() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let token = SessionToken.issue(subject: "owner", idleTTL: 3600, secret: secret, now: t0)
        let wrongSecret = Data("wrong-secret-32-bytes-padding!!xx".utf8)
        XCTAssertNil(SessionToken.verify(token, secret: wrongSecret, maxAge: 12 * 3600, now: t0))
    }

    func test_verify_tamperedToken_returnsNil() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let token = SessionToken.issue(subject: "owner", idleTTL: 3600, secret: secret, now: t0)
        // Flip one character in the MAC (last part)
        var parts = token.split(separator: ".", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
        parts[3] = String(parts[3].dropLast()) + (parts[3].last == "A" ? "B" : "A")
        let tampered = parts.joined(separator: ".")
        XCTAssertNil(SessionToken.verify(tampered, secret: secret, maxAge: 12 * 3600, now: t0))
    }

    // MARK: - Idle expiry

    func test_verify_idleExpired_returnsNil() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        // idleTTL = 600 s (10 min); verify at t0 + 601 → idle-expired
        let token = SessionToken.issue(subject: "owner", idleTTL: 600, secret: secret, now: t0)
        let laterNow = t0.addingTimeInterval(601)
        XCTAssertNil(SessionToken.verify(token, secret: secret, maxAge: 12 * 3600, now: laterNow),
                     "Token past its idle window must be rejected")
    }

    func test_verify_atIdleExpiry_returnsNil() {
        // Exactly at exp (exp == now means NOT strictly greater than now → expired)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let token = SessionToken.issue(subject: "owner", idleTTL: 600, secret: secret, now: t0)
        let atExpiry = t0.addingTimeInterval(600)
        XCTAssertNil(SessionToken.verify(token, secret: secret, maxAge: 12 * 3600, now: atExpiry))
    }

    func test_verify_justBeforeIdleExpiry_succeeds() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let token = SessionToken.issue(subject: "owner", idleTTL: 600, secret: secret, now: t0)
        let justBefore = t0.addingTimeInterval(599)
        XCTAssertEqual(SessionToken.verify(token, secret: secret, maxAge: 12 * 3600, now: justBefore), "owner")
    }

    // MARK: - Absolute session cap

    func test_verify_absoluteCapExceeded_returnsNil() {
        // Craft a token with an old issuedAt but a fresh-looking exp.
        // Simulate: issued 13 hours ago, but exp is 1 hour from now.
        let longAgo = Date(timeIntervalSince1970: 1_000_000)
        // Issue at longAgo with idleTTL = 13*3600 + 3600 so exp is in the future at "now"
        // But the maxAge cap (12h) is breached because now - issuedAt > 12h.
        let bigIdle: TimeInterval = 13 * 3600 + 3600  // exp = longAgo + 14h
        let token = SessionToken.issue(subject: "owner", idleTTL: bigIdle, secret: secret, now: longAgo)

        // "now" = longAgo + 13h (13 * 3600 = 46800 seconds)
        let now = longAgo.addingTimeInterval(13 * 3600)
        // exp = longAgo + 14h → still in the future, so idle-expiry would pass.
        // But now - issuedAt = 13h > maxAge (12h) → should be rejected.
        XCTAssertNil(SessionToken.verify(token, secret: secret, maxAge: 12 * 3600, now: now),
                     "Token must be rejected when absolute session cap is exceeded even with a fresh-looking exp")
    }

    func test_verify_justWithinAbsoluteCap_succeeds() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        // Issue with large idleTTL; check at exactly 12h - 1s (within cap)
        let token = SessionToken.issue(subject: "owner", idleTTL: 13 * 3600, secret: secret, now: t0)
        let justWithin = t0.addingTimeInterval(12 * 3600 - 1)
        XCTAssertEqual(SessionToken.verify(token, secret: secret, maxAge: 12 * 3600, now: justWithin), "owner")
    }

    // MARK: - Slide

    func test_slide_renewsExpButKeepsIssuedAt() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let token = SessionToken.issue(subject: "owner", idleTTL: 600, secret: secret, now: t0)

        // Slide at t0 + 300 (halfway through idle window)
        let slideTime = t0.addingTimeInterval(300)
        let slid = SessionToken.slide(token, secret: secret, idleTTL: 600, maxAge: 12 * 3600, now: slideTime)
        XCTAssertNotNil(slid, "Slide should succeed within idle window")

        // The slid token must verify further in the future (t0 + 300 + 600 - 1 = t0 + 899)
        let future = slideTime.addingTimeInterval(599)
        XCTAssertEqual(SessionToken.verify(slid!, secret: secret, maxAge: 12 * 3600, now: future), "owner",
                       "Slid token must be valid up to the new idle window")

        // The slid token must preserve issuedAt. Verify that the absolute cap is still enforced
        // relative to the original issue time (t0), not the slide time.
        // At t0 + 12*3600 + 1 it must be rejected (cap exceeded regardless of slid exp).
        let pastAbsoluteCap = t0.addingTimeInterval(12 * 3600 + 1)
        XCTAssertNil(SessionToken.verify(slid!, secret: secret, maxAge: 12 * 3600, now: pastAbsoluteCap),
                     "Slid token must respect the original issuedAt for the absolute cap")
    }

    func test_slide_returnsNil_afterIdleExpiry() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let token = SessionToken.issue(subject: "owner", idleTTL: 600, secret: secret, now: t0)

        // Try to slide after idle expiry
        let afterExpiry = t0.addingTimeInterval(601)
        let slid = SessionToken.slide(token, secret: secret, idleTTL: 600, maxAge: 12 * 3600, now: afterExpiry)
        XCTAssertNil(slid, "Slide must return nil when the token is idle-expired")
    }

    func test_slide_returnsNil_afterAbsoluteCap() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        // Issue with a large idle TTL so exp stays in the future, but maxAge is exceeded
        let token = SessionToken.issue(subject: "owner", idleTTL: 48 * 3600, secret: secret, now: t0)

        // "now" = t0 + 13h (past the 12h cap); exp is 48h from t0, so idle check would pass
        let pastCap = t0.addingTimeInterval(13 * 3600)
        let slid = SessionToken.slide(token, secret: secret, idleTTL: 600, maxAge: 12 * 3600, now: pastCap)
        XCTAssertNil(slid, "Slide must return nil when the absolute session cap is exceeded")
    }

    func test_slide_newTokenVerifiesCorrectly() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let token = SessionToken.issue(subject: "owner", idleTTL: 600, secret: secret, now: t0)

        let slideTime = t0.addingTimeInterval(100)
        let slid = SessionToken.slide(token, secret: secret, idleTTL: 600, maxAge: 12 * 3600, now: slideTime)!

        // The slid token must have the correct MAC (roundtrip verify immediately after slide)
        XCTAssertEqual(SessionToken.verify(slid, secret: secret, maxAge: 12 * 3600, now: slideTime), "owner")
    }

    // MARK: - Token format

    func test_tokenHasFourParts() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let token = SessionToken.issue(subject: "owner", idleTTL: 3600, secret: secret, now: t0)
        let parts = token.split(separator: ".", maxSplits: 3, omittingEmptySubsequences: false)
        XCTAssertEqual(parts.count, 4, "Token must have 4 dot-separated parts: subject.issuedAt.exp.mac")
    }

    func test_verify_threePartOldFormat_returnsNil() {
        // Old 3-part tokens (from before this change) must be rejected.
        let secret = Data("server-secret-32-bytes-or-more!!".utf8)
        let oldStyleToken = "owner.9999999999.invalidsig"
        XCTAssertNil(SessionToken.verify(oldStyleToken, secret: secret, maxAge: 12 * 3600))
    }
}
