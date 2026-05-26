import XCTest
import CryptoKit
@testable import PeerDropSecurity

final class DeterministicCryptoTests: XCTestCase {
    func test_sameSeed_producesSameKey() {
        let seed = Data(repeating: 0xAB, count: 32)
        let k1 = DeterministicCrypto.curve25519AgreementKey(seed: seed)
        let k2 = DeterministicCrypto.curve25519AgreementKey(seed: seed)
        XCTAssertEqual(k1.rawRepresentation, k2.rawRepresentation)
    }

    func test_differentSeed_differentKey() {
        let k1 = DeterministicCrypto.curve25519AgreementKey(seed: Data(repeating: 0x01, count: 32))
        let k2 = DeterministicCrypto.curve25519AgreementKey(seed: Data(repeating: 0x02, count: 32))
        XCTAssertNotEqual(k1.rawRepresentation, k2.rawRepresentation)
    }

    func test_sameSeed_producesSameSigningKey() {
        let seed = Data(repeating: 0x42, count: 32)
        let k1 = DeterministicCrypto.curve25519SigningKey(seed: seed)
        let k2 = DeterministicCrypto.curve25519SigningKey(seed: seed)
        XCTAssertEqual(k1.rawRepresentation, k2.rawRepresentation)
    }
}
