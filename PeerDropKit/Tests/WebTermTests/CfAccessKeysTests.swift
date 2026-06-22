import XCTest
import JWTKit
@testable import webterm

final class CfAccessKeysTests: XCTestCase {

    // MARK: - Claims type shared across tests

    struct CfClaims: JWTPayload {
        let aud: AudienceClaim
        let email: String
        let exp: ExpirationClaim
        func verify(using algorithm: some JWTAlgorithm) throws { try exp.verifyNotExpired() }
    }

    // MARK: - certsURL

    func test_certsURL_shape() throws {
        let url = try CfAccessKeys.certsURL(team: "myteam")
        XCTAssertEqual(url.absoluteString,
                       "https://myteam.cloudflareaccess.com/cdn-cgi/access/certs")
    }

    // MARK: - keyCollection(fromJWKSJSON:) — parse errors

    func test_invalidJSON_throws() async {
        do {
            _ = try await CfAccessKeys.keyCollection(fromJWKSJSON: "not json at all")
            XCTFail("expected throw for invalid JSON")
        } catch {
            // Any error is fine — the point is it throws rather than succeeding silently.
        }
    }

    func test_emptyKeys_doesNotThrow() async throws {
        // A well-formed JWKS with an empty keys array is valid JSON and should load
        // without error (the resulting collection just has no keys).
        _ = try await CfAccessKeys.keyCollection(fromJWKSJSON: #"{"keys":[]}"#)
    }

    // MARK: - Full round-trip: generate key → export public JWKS → load → verify token

    func test_loadJWKSthenVerifyToken() async throws {
        // 1. Generate an ES256 key pair.
        let privateKey = ES256PrivateKey()

        // 2. Extract the public key coordinates so we can build a JWK manually.
        //    ES256PrivateKey = ECDSA.PrivateKey<P256>; .publicKey.parameters is (x, y)
        //    as base64-encoded strings. The JWK fields use the same base64 encoding.
        guard let params = privateKey.publicKey.parameters else {
            XCTFail("Could not extract EC public key parameters")
            return
        }

        // 3. Build the JWKS JSON by hand using Foundation's JSONEncoder on a JWK struct.
        //    JWK.ecdsa(_:identifier:x:y:curve:privateKey:) constructs a public EC JWK
        //    (no `d` private exponent) when privateKey is nil.
        let jwk = JWK.ecdsa(
            .es256,
            identifier: JWKIdentifier(string: "k1"),
            x: params.x,
            y: params.y,
            curve: .p256,
            privateKey: nil   // public key only — as Cloudflare would publish
        )
        let jwks = JWKS(keys: [jwk])
        let jwksData = try JSONEncoder().encode(jwks)
        let jwksJSON = String(data: jwksData, encoding: .utf8)!

        // 4. Load the public JWKS into a verify-only collection via CfAccessKeys.
        let verifyKeys = try await CfAccessKeys.keyCollection(fromJWKSJSON: jwksJSON)

        // 5. Sign a token with the PRIVATE key (simulating what Cloudflare Access does).
        let signingKeys = JWTKeyCollection()
        await signingKeys.add(ecdsa: privateKey, kid: "k1")
        let token = try await signingKeys.sign(
            CfClaims(
                aud: "AUD-TAG",
                email: "owner@example.com",
                exp: .init(value: Date().addingTimeInterval(3600))
            ),
            kid: "k1"
        )

        // 6. Verify via CfAccessVerifier built from the loaded public keys.
        let verifier = CfAccessVerifier(
            audience: "AUD-TAG",
            ownerEmail: "owner@example.com",
            keys: verifyKeys
        )
        let email = try await verifier.verify(token)
        XCTAssertEqual(email, "owner@example.com")
    }

    // MARK: - Cross-key rejection

    func test_differentKey_cannotVerifyToken() async throws {
        // Token signed by key A; JWKS contains key B → verification must fail.
        let keyA = ES256PrivateKey()
        let keyB = ES256PrivateKey()

        // Build a JWKS containing only key B's public key.
        guard let paramsB = keyB.publicKey.parameters else {
            XCTFail("Could not extract EC public key parameters for key B")
            return
        }
        let jwkB = JWK.ecdsa(
            .es256,
            identifier: JWKIdentifier(string: "kb"),
            x: paramsB.x,
            y: paramsB.y,
            curve: .p256,
            privateKey: nil
        )
        let jwksData = try JSONEncoder().encode(JWKS(keys: [jwkB]))
        let verifyKeys = try await CfAccessKeys.keyCollection(
            fromJWKSJSON: String(data: jwksData, encoding: .utf8)!
        )

        // Sign with key A.
        let signingKeys = JWTKeyCollection()
        await signingKeys.add(ecdsa: keyA, kid: "ka")
        let token = try await signingKeys.sign(
            CfClaims(
                aud: "AUD",
                email: "owner@example.com",
                exp: .init(value: Date().addingTimeInterval(3600))
            ),
            kid: "ka"
        )

        // Verify against key B — must throw.
        let verifier = CfAccessVerifier(audience: "AUD", ownerEmail: "owner@example.com", keys: verifyKeys)
        do {
            _ = try await verifier.verify(token)
            XCTFail("expected verification to fail when key mismatch")
        } catch {
            // Expected — wrong key.
        }
    }

    // MARK: - Key swap via CfAccessKeySource

    func test_keySwap_verifierPicksUpNewKeys() async throws {
        // Set up key A (initial) and key B (rotated).
        let keyA = ES256PrivateKey()
        let keyB = ES256PrivateKey()

        // Build public JWKS for both keys.
        func publicJWKSCollection(_ key: ES256PrivateKey, kid: String) async throws -> JWTKeyCollection {
            guard let params = key.publicKey.parameters else {
                XCTFail("Could not extract EC public key parameters"); fatalError()
            }
            let jwk = JWK.ecdsa(.es256, identifier: JWKIdentifier(string: kid),
                                 x: params.x, y: params.y, curve: .p256, privateKey: nil)
            let json = String(data: try JSONEncoder().encode(JWKS(keys: [jwk])), encoding: .utf8)!
            return try await CfAccessKeys.keyCollection(fromJWKSJSON: json)
        }

        let keysA = try await publicJWKSCollection(keyA, kid: "ka")
        let keysB = try await publicJWKSCollection(keyB, kid: "kb")

        // Sign a token with key B (simulating Cloudflare after key rotation).
        let signingKeys = JWTKeyCollection()
        await signingKeys.add(ecdsa: keyB, kid: "kb")
        let token = try await signingKeys.sign(
            CfClaims(aud: "AUD", email: "owner@example.com",
                     exp: .init(value: Date().addingTimeInterval(3600))),
            kid: "kb"
        )

        // 1. Verifier initialized with key A — must FAIL (token signed with B).
        let verifier = CfAccessVerifier(audience: "AUD", ownerEmail: "owner@example.com", keys: keysA)
        do {
            _ = try await verifier.verify(token)
            XCTFail("expected verification failure before key swap")
        } catch {
            // Expected: wrong key.
        }

        // 2. Swap in key B (simulating periodic auto-refresh picking up rotated keys).
        await verifier.source.replace(with: keysB)

        // 3. After swap, verify must SUCCEED.
        let email = try await verifier.verify(token)
        XCTAssertEqual(email, "owner@example.com")
    }
}
