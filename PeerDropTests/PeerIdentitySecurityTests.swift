import XCTest
@testable import PeerDrop

final class PeerIdentitySecurityTests: XCTestCase {

    func testPeerIdentityIncludesIdentityPublicKey() {
        let identity = PeerIdentity.current
        XCTAssertNotNil(identity.identityPublicKey)
        XCTAssertEqual(identity.identityPublicKey?.count, 32)
    }

    func testPeerIdentityIncludesFingerprint() {
        let identity = PeerIdentity.current
        XCTAssertNotNil(identity.identityFingerprint)
        let parts = identity.identityFingerprint!.split(separator: " ")
        XCTAssertEqual(parts.count, 5)
    }

    func testPeerIdentityPublicKeyIsPersistent() {
        let pk1 = PeerIdentity.current.identityPublicKey
        let pk2 = PeerIdentity.current.identityPublicKey
        XCTAssertEqual(pk1, pk2)
    }
}
