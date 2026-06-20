import XCTest
import JWTKit
@testable import webterm

final class CfAccessVerifierTests: XCTestCase {
    struct CfClaims: JWTPayload {
        let aud: AudienceClaim
        let email: String
        let exp: ExpirationClaim
        func verify(using algorithm: some JWTAlgorithm) throws { try exp.verifyNotExpired() }
    }

    func test_validTokenForOwnerPasses() async throws {
        let keys = JWTKeyCollection()
        let key = ES256PrivateKey()
        await keys.add(ecdsa: key, kid: "test")
        let token = try await keys.sign(
            CfClaims(aud: "AUD123", email: "owner@example.com",
                     exp: .init(value: Date().addingTimeInterval(3600))), kid: "test")
        let v = CfAccessVerifier(audience: "AUD123", ownerEmail: "owner@example.com", keys: keys)
        let email = try await v.verify(token)
        XCTAssertEqual(email, "owner@example.com")
    }

    func test_wrongAudienceRejected() async throws {
        let keys = JWTKeyCollection()
        let key = ES256PrivateKey()
        await keys.add(ecdsa: key, kid: "test")
        let token = try await keys.sign(
            CfClaims(aud: "WRONG", email: "owner@example.com",
                     exp: .init(value: Date().addingTimeInterval(3600))), kid: "test")
        let v = CfAccessVerifier(audience: "AUD123", ownerEmail: "owner@example.com", keys: keys)
        await XCTAssertThrowsErrorAsync(try await v.verify(token))
    }

    func test_wrongEmailRejected() async throws {
        let keys = JWTKeyCollection()
        let key = ES256PrivateKey()
        await keys.add(ecdsa: key, kid: "test")
        let token = try await keys.sign(
            CfClaims(aud: "AUD123", email: "intruder@example.com",
                     exp: .init(value: Date().addingTimeInterval(3600))), kid: "test")
        let v = CfAccessVerifier(audience: "AUD123", ownerEmail: "owner@example.com", keys: keys)
        await XCTAssertThrowsErrorAsync(try await v.verify(token))
    }
}

func XCTAssertThrowsErrorAsync(_ expr: @autoclosure () async throws -> some Any,
                               file: StaticString = #file, line: UInt = #line) async {
    do { _ = try await expr(); XCTFail("expected throw", file: file, line: line) } catch {}
}
