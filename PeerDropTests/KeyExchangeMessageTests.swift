import XCTest
import CryptoKit
@testable import PeerDrop

final class KeyExchangeMessageTests: XCTestCase {

    func testHelloMessageCodable() throws {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let signingKey = Curve25519.Signing.PrivateKey()
        let msg = KeyExchangeMessage.hello(
            publicKey: key.publicKey.rawRepresentation,
            signingPublicKey: signingKey.publicKey.rawRepresentation,
            fingerprint: "A1B2 C3D4 E5F6 G7H8 I9J0",
            deviceName: "iPhone"
        )

        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(KeyExchangeMessage.self, from: data)

        if case .hello(let pk, let spk, let fp, let name) = decoded {
            XCTAssertEqual(pk, key.publicKey.rawRepresentation)
            XCTAssertEqual(spk, signingKey.publicKey.rawRepresentation)
            XCTAssertEqual(fp, "A1B2 C3D4 E5F6 G7H8 I9J0")
            XCTAssertEqual(name, "iPhone")
        } else {
            XCTFail("Expected .hello")
        }
    }

    func testVerifyMessageCodable() throws {
        let nonce = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let msg = KeyExchangeMessage.verify(nonce: nonce)
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(KeyExchangeMessage.self, from: data)

        if case .verify(let n) = decoded {
            XCTAssertEqual(n, nonce)
        } else {
            XCTFail("Expected .verify")
        }
    }

    func testConfirmMessageCodable() throws {
        let sig = Data((0..<64).map { _ in UInt8.random(in: 0...255) })
        let msg = KeyExchangeMessage.confirm(signature: sig)
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(KeyExchangeMessage.self, from: data)

        if case .confirm(let s) = decoded {
            XCTAssertEqual(s, sig)
        } else {
            XCTFail("Expected .confirm")
        }
    }

    func testKeyChangeMessageCodable() throws {
        let oldFp = "A1B2 C3D4 E5F6 G7H8 I9J0"
        let newKey = Data(repeating: 0xAA, count: 32)
        let msg = KeyExchangeMessage.keyChanged(
            oldFingerprint: oldFp,
            newPublicKey: newKey
        )
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(KeyExchangeMessage.self, from: data)

        if case .keyChanged(let ofp, let npk) = decoded {
            XCTAssertEqual(ofp, oldFp)
            XCTAssertEqual(npk, newKey)
        } else {
            XCTFail("Expected .keyChanged")
        }
    }
}
