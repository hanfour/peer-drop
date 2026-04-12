import XCTest
import CryptoKit
@testable import PeerDrop

final class TrustedContactTests: XCTestCase {

    func testTrustLevelOrdering() {
        XCTAssertTrue(TrustLevel.verified.isAtLeast(.linked))
        XCTAssertTrue(TrustLevel.verified.isAtLeast(.unknown))
        XCTAssertTrue(TrustLevel.linked.isAtLeast(.unknown))
        XCTAssertFalse(TrustLevel.unknown.isAtLeast(.linked))
        XCTAssertFalse(TrustLevel.linked.isAtLeast(.verified))
    }

    func testTrustedContactCreation() {
        let keyPair = Curve25519.KeyAgreement.PrivateKey()
        let contact = TrustedContact(
            id: UUID(),
            displayName: "Bob",
            identityPublicKey: keyPair.publicKey.rawRepresentation,
            trustLevel: .verified,
            firstConnected: Date()
        )
        XCTAssertEqual(contact.displayName, "Bob")
        XCTAssertEqual(contact.trustLevel, .verified)
        XCTAssertFalse(contact.isBlocked)
        XCTAssertNil(contact.mailboxId)
        XCTAssertNil(contact.userId)
    }

    func testKeyFingerprint() {
        let keyPair = Curve25519.KeyAgreement.PrivateKey()
        let contact = TrustedContact(
            id: UUID(),
            displayName: "Bob",
            identityPublicKey: keyPair.publicKey.rawRepresentation,
            trustLevel: .verified,
            firstConnected: Date()
        )
        let fp = contact.keyFingerprint
        let parts = fp.split(separator: " ")
        XCTAssertEqual(parts.count, 5)
    }

    func testCodableRoundTrip() throws {
        let keyPair = Curve25519.KeyAgreement.PrivateKey()
        let original = TrustedContact(
            id: UUID(),
            displayName: "Carol",
            identityPublicKey: keyPair.publicKey.rawRepresentation,
            trustLevel: .linked,
            firstConnected: Date(),
            lastVerified: nil,
            mailboxId: "mbx_test",
            userId: nil,
            isBlocked: false
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TrustedContact.self, from: data)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.displayName, original.displayName)
        XCTAssertEqual(decoded.identityPublicKey, original.identityPublicKey)
        XCTAssertEqual(decoded.trustLevel, original.trustLevel)
        XCTAssertEqual(decoded.mailboxId, original.mailboxId)
    }

    func testKeyChangeDetection() {
        let oldKey = Curve25519.KeyAgreement.PrivateKey()
        let newKey = Curve25519.KeyAgreement.PrivateKey()
        let contact = TrustedContact(
            id: UUID(),
            displayName: "Bob",
            identityPublicKey: oldKey.publicKey.rawRepresentation,
            trustLevel: .verified,
            firstConnected: Date()
        )
        XCTAssertTrue(contact.matchesKey(oldKey.publicKey.rawRepresentation))
        XCTAssertFalse(contact.matchesKey(newKey.publicKey.rawRepresentation))
    }

    func testTrustLevelSFSymbol() {
        XCTAssertEqual(TrustLevel.verified.sfSymbol, "lock.shield")
        XCTAssertEqual(TrustLevel.linked.sfSymbol, "link.circle")
        XCTAssertEqual(TrustLevel.unknown.sfSymbol, "exclamationmark.triangle")
    }
}
