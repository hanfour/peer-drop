import XCTest
import CryptoKit
import PeerDropSecurity
@testable import PeerDropCore

/// Deterministic random source for tests.
final class CountingRandom: RendezvousRandomSource {
    private var next: UInt8
    init(seed: UInt8) { next = seed }
    func randomBytes(count: Int) -> Data {
        Data((0..<count).map { _ in defer { next &+= 1 }; return next })
    }
}

final class RendezvousSignalingCryptoTests: XCTestCase {

    private let day = 20_385

    /// Builds two connected ciphers via the hello exchange (the production path).
    private func connectedPair(
        day: Int = 20_385
    ) throws -> (alice: RendezvousSignalingCipher, bob: RendezvousSignalingCipher,
                 aliceID: RendezvousTestIdentity, bobID: RendezvousTestIdentity) {
        let a = RendezvousTestIdentity(), b = RendezvousTestIdentity()
        let ha = try RendezvousSignalingHandshake(
            provider: IdentityRendezvousSecretProvider(identity: a), peerKey: b.raw, day: day)
        let hb = try RendezvousSignalingHandshake(
            provider: IdentityRendezvousSecretProvider(identity: b), peerKey: a.raw, day: day)
        let ca = try ha.accept(peerHelloFrame: hb.helloFrame)
        let cb = try hb.accept(peerHelloFrame: ha.helloFrame)
        return (ca, cb, a, b)
    }

    // MARK: - Key, direction, session id

    func testSignalingKeyKnownAnswerAndSymmetry() throws {
        let a = Data(repeating: 0x02, count: 32), b = Data(repeating: 0x03, count: 32)
        let s = SymmetricKey(data: Data(repeating: 0x11, count: 32))
        let k1 = try RendezvousSignalingCrypto.signalingKey(sharedSecret: s, myKey: a, peerKey: b, day: 20000)
        let k2 = try RendezvousSignalingCrypto.signalingKey(sharedSecret: s, myKey: b, peerKey: a, day: 20000)
        XCTAssertEqual(k1.rawData.hexString, "1fca3ce9b667206eaf3f77f88fce8f1da2cf565c938c57aeaa730586c6f413ef")
        XCTAssertEqual(k1.rawData, k2.rawData)
        let other = try RendezvousSignalingCrypto.signalingKey(sharedSecret: s, myKey: a, peerKey: b, day: 20001)
        XCTAssertNotEqual(k1.rawData, other.rawData)
    }

    func testDirectionsAreOppositeAndOrdered() throws {
        let small = Data(repeating: 0x02, count: 32), large = Data(repeating: 0x03, count: 32)
        XCTAssertEqual(try RendezvousSignalingCrypto.localDirection(myKey: small, peerKey: large), .smallerKey)
        XCTAssertEqual(try RendezvousSignalingCrypto.localDirection(myKey: large, peerKey: small), .largerKey)
        XCTAssertEqual(RendezvousDirection.smallerKey.rawValue, 0x01)
        XCTAssertEqual(RendezvousDirection.largerKey.rawValue, 0x02)
        XCTAssertThrowsError(try RendezvousSignalingCrypto.localDirection(myKey: small, peerKey: small))
    }

    func testNonceLayoutAndDirectionPrefixesDiffer() {
        let n1 = RendezvousSignalingCrypto.nonceBytes(direction: .smallerKey, counter: 0x0102030405060708)
        let n2 = RendezvousSignalingCrypto.nonceBytes(direction: .largerKey, counter: 0x0102030405060708)
        XCTAssertEqual(Array(n1), [0, 0, 0, 1, 1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(Array(n2), [0, 0, 0, 2, 1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertNotEqual(n1, n2)
    }

    func testAADLayout() {
        let sid = Data(0..<16)
        let aad = RendezvousSignalingCrypto.aad(day: 0x0A0B, sessionID: sid, direction: .largerKey)
        XCTAssertEqual(aad, Data("rv-sig-v1".utf8) + Data([0, 0, 0, 0, 0, 0, 0x0A, 0x0B]) + sid + Data([0x02]))
    }

    func testSessionIDIsSmallerKeyContributionFirst() throws {
        let a = RendezvousTestIdentity(), b = RendezvousTestIdentity()
        let ha = try RendezvousSignalingHandshake(
            provider: IdentityRendezvousSecretProvider(identity: a), peerKey: b.raw, day: day, random: CountingRandom(seed: 0x10))
        let hb = try RendezvousSignalingHandshake(
            provider: IdentityRendezvousSecretProvider(identity: b), peerKey: a.raw, day: day, random: CountingRandom(seed: 0x80))
        let ca = try ha.accept(peerHelloFrame: hb.helloFrame)
        let cb = try hb.accept(peerHelloFrame: ha.helloFrame)
        XCTAssertEqual(ca.sessionID, cb.sessionID)
        XCTAssertEqual(ca.sessionID.count, 16)
        let aContribution = Data((0x10..<0x18).map { UInt8($0) })
        let bContribution = Data((0x80..<0x88).map { UInt8($0) })
        let aSmaller = a.raw.lexicographicallyPrecedes(b.raw)
        XCTAssertEqual(ca.sessionID, aSmaller ? aContribution + bContribution : bContribution + aContribution)
    }

    func testHelloFrameShapeAndParsing() throws {
        let a = RendezvousTestIdentity(), b = RendezvousTestIdentity()
        let h = try RendezvousSignalingHandshake(
            provider: IdentityRendezvousSecretProvider(identity: a), peerKey: b.raw, day: day, random: CountingRandom(seed: 0))
        XCTAssertEqual(h.helloFrame, #"{"t":"hello","r":"AAECAwQFBgc"}"#)
        XCTAssertEqual(RendezvousHello.parse(#"{"t":"hello","r":"AAECAwQFBgc"}"#), Data(0..<8))
        XCTAssertEqual(RendezvousHello.parse(#"{"r":"AAECAwQFBgc","t":"hello"}"#), Data(0..<8))
        XCTAssertNil(RendezvousHello.parse(#"{"t":"hello","r":"AAECAwQFBgd"}"#))   // non-canonical
        XCTAssertNil(RendezvousHello.parse(#"{"t":"hello","r":"AAECAwQFBgcI"}"#))  // 9 bytes
        XCTAssertNil(RendezvousHello.parse(#"{"t":"joined"}"#))
        XCTAssertNil(RendezvousHello.parse("ping"))
        XCTAssertNil(RendezvousHello.parse(#"{"t":"hello","r":7}"#))
    }

    func testReflectedHelloRejectedAndHandshakeSingleUse() throws {
        let a = RendezvousTestIdentity(), b = RendezvousTestIdentity()
        let ha = try RendezvousSignalingHandshake(
            provider: IdentityRendezvousSecretProvider(identity: a), peerKey: b.raw, day: day)
        // Operator bounces my own hello back to me.
        XCTAssertThrowsError(try ha.accept(peerHelloFrame: ha.helloFrame)) {
            XCTAssertEqual($0 as? RendezvousSignalingError, .reflectedHello)
        }
        XCTAssertThrowsError(try ha.accept(peerHelloFrame: "garbage")) {
            XCTAssertEqual($0 as? RendezvousSignalingError, .invalidHello)
        }
        let hb = try RendezvousSignalingHandshake(
            provider: IdentityRendezvousSecretProvider(identity: b), peerKey: a.raw, day: day)
        _ = try ha.accept(peerHelloFrame: hb.helloFrame)
        XCTAssertThrowsError(try ha.accept(peerHelloFrame: hb.helloFrame)) {
            XCTAssertEqual($0 as? RendezvousSignalingError, .handshakeAlreadyCompleted)
        }
    }

    func testHandshakeRejectsEqualKeys() {
        let a = RendezvousTestIdentity()
        XCTAssertThrowsError(try RendezvousSignalingHandshake(
            provider: IdentityRendezvousSecretProvider(identity: a), peerKey: a.raw, day: day))
    }

    // MARK: - AEAD

    func testRoundTripBothDirections() throws {
        let (alice, bob, _, _) = try connectedPair()
        for i in 0..<5 {
            let m = Data("offer \(i)".utf8)
            XCTAssertEqual(try bob.open(try alice.seal(m)), m)
            let r = Data("answer \(i)".utf8)
            XCTAssertEqual(try alice.open(try bob.seal(r)), r)
        }
        XCTAssertEqual(try bob.open(try alice.seal(Data())), Data())
    }

    func testWireFormatIsCounterThenCiphertextAndTag() throws {
        let (alice, _, _, _) = try connectedPair()
        let w0 = try alice.seal(Data("abc".utf8))
        let w1 = try alice.seal(Data("abc".utf8))
        XCTAssertEqual(w0.count, 8 + 3 + 16)
        XCTAssertEqual(Array(w0.prefix(8)), [0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(Array(w1.prefix(8)), [0, 0, 0, 0, 0, 0, 0, 1])
        XCTAssertNotEqual(w0.dropFirst(8), w1.dropFirst(8))
    }

    func testTamperAnyByteFails() throws {
        let (alice, bob, _, _) = try connectedPair()
        let wire = try alice.seal(Data("v=0 o=- 4611 IN IP4 10.0.0.2".utf8))
        for i in 0..<wire.count {
            var t = wire
            t[t.startIndex + i] ^= 0x01
            XCTAssertThrowsError(try bob.open(t), "byte \(i)")
        }
        // Truncation in every region fails.
        for len in [0, 1, 7, 8, 9, 8 + 16 - 1, wire.count - 1] {
            XCTAssertThrowsError(try bob.open(wire.prefix(len)), "len \(len)")
        }
        // Failed attempts did not advance state: the genuine frame still opens.
        XCTAssertNoThrow(try bob.open(wire))
    }

    func testReplayAndRegressionRejectedGapsAllowed() throws {
        let (alice, bob, _, _) = try connectedPair()
        let f0 = try alice.seal(Data("0".utf8))
        let f1 = try alice.seal(Data("1".utf8))
        let f2 = try alice.seal(Data("2".utf8))
        let f3 = try alice.seal(Data("3".utf8))
        XCTAssertNoThrow(try bob.open(f0))
        XCTAssertThrowsError(try bob.open(f0)) { XCTAssertEqual($0 as? RendezvousSignalingError, .replayedOrStaleCounter) }
        XCTAssertNoThrow(try bob.open(f2))  // gap (f1 skipped) is allowed
        XCTAssertThrowsError(try bob.open(f1)) { XCTAssertEqual($0 as? RendezvousSignalingError, .replayedOrStaleCounter) }
        XCTAssertThrowsError(try bob.open(f2))
        XCTAssertEqual(try bob.open(f3), Data("3".utf8))
    }

    func testReflectionOfOwnFrameFails() throws {
        let (alice, _, _, _) = try connectedPair()
        let mine = try alice.seal(Data("offer".utf8))
        XCTAssertThrowsError(try alice.open(mine)) {
            XCTAssertEqual($0 as? RendezvousSignalingError, .authenticationFailed)
        }
    }

    func testCrossSessionFails_replayedOldOffer() throws {
        // Session 1: the operator records Alice's encrypted offer and her hello.
        let a = RendezvousTestIdentity(), b = RendezvousTestIdentity()
        let pa = IdentityRendezvousSecretProvider(identity: a), pb = IdentityRendezvousSecretProvider(identity: b)
        let ha1 = try RendezvousSignalingHandshake(provider: pa, peerKey: b.raw, day: day)
        let hb1 = try RendezvousSignalingHandshake(provider: pb, peerKey: a.raw, day: day)
        let ca1 = try ha1.accept(peerHelloFrame: hb1.helloFrame)
        _ = try hb1.accept(peerHelloFrame: ha1.helloFrame)
        let oldOffer = try ca1.seal(Data("old offer".utf8))

        // Session 2: Bob joins again with a fresh contribution; the operator
        // replays Alice's OLD hello and OLD offer to him.
        let hb2 = try RendezvousSignalingHandshake(provider: pb, peerKey: a.raw, day: day)
        let cb2 = try hb2.accept(peerHelloFrame: ha1.helloFrame)
        XCTAssertNotEqual(cb2.sessionID, ca1.sessionID)
        XCTAssertThrowsError(try cb2.open(oldOffer)) {
            XCTAssertEqual($0 as? RendezvousSignalingError, .authenticationFailed)
        }
    }

    func testCrossDayFails() throws {
        let a = RendezvousTestIdentity(), b = RendezvousTestIdentity()
        let pa = IdentityRendezvousSecretProvider(identity: a), pb = IdentityRendezvousSecretProvider(identity: b)
        let sid = Data(repeating: 7, count: 16)
        let keyA1 = try RendezvousSignalingCrypto.signalingKey(provider: pa, peerKey: b.raw, day: day)
        let keyB1 = try RendezvousSignalingCrypto.signalingKey(provider: pb, peerKey: a.raw, day: day)
        let keyB2 = try RendezvousSignalingCrypto.signalingKey(provider: pb, peerKey: a.raw, day: day + 1)
        let dirA = try RendezvousSignalingCrypto.localDirection(myKey: a.raw, peerKey: b.raw)
        let sender = try RendezvousSignalingCipher(key: keyA1, localDirection: dirA, day: day, sessionID: sid)
        let wire = try sender.seal(Data("x".utf8))
        // Right key, wrong day in AAD.
        let wrongDayAAD = try RendezvousSignalingCipher(key: keyB1, localDirection: dirA.peer, day: day + 1, sessionID: sid)
        XCTAssertThrowsError(try wrongDayAAD.open(wire))
        // Next day's key.
        let wrongDayKey = try RendezvousSignalingCipher(key: keyB2, localDirection: dirA.peer, day: day + 1, sessionID: sid)
        XCTAssertThrowsError(try wrongDayKey.open(wire))
        // Wrong session id.
        let wrongSession = try RendezvousSignalingCipher(key: keyB1, localDirection: dirA.peer, day: day,
                                                         sessionID: Data(repeating: 8, count: 16))
        XCTAssertThrowsError(try wrongSession.open(wire))
        // Control: correct parameters open.
        let good = try RendezvousSignalingCipher(key: keyB1, localDirection: dirA.peer, day: day, sessionID: sid)
        XCTAssertEqual(try good.open(wire), Data("x".utf8))
    }

    func testCipherRejectsBadSessionIDLength() {
        XCTAssertThrowsError(try RendezvousSignalingCipher(
            key: SymmetricKey(size: .bits256), localDirection: .smallerKey, day: 1, sessionID: Data(count: 15)))
    }

    func testSendCounterOverflowGuard() throws {
        let key = SymmetricKey(size: .bits256), sid = Data(repeating: 1, count: 16)
        let s = try RendezvousSignalingCipher(key: key, localDirection: .smallerKey, day: 1, sessionID: sid,
                                              initialSendCounter: UInt64.max - 1)
        let r = try RendezvousSignalingCipher(key: key, localDirection: .largerKey, day: 1, sessionID: sid)
        let last = try s.seal(Data("last".utf8))
        XCTAssertEqual(Array(last.prefix(8)), [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE])
        XCTAssertEqual(try r.open(last), Data("last".utf8))
        XCTAssertThrowsError(try s.seal(Data("one more".utf8))) {
            XCTAssertEqual($0 as? RendezvousSignalingError, .sendCounterExhausted)
        }
        XCTAssertThrowsError(try s.seal(Data()))  // stays exhausted
    }

    func testReceiverRejectsMaxCounter() throws {
        let key = SymmetricKey(size: .bits256), sid = Data(repeating: 1, count: 16)
        let r = try RendezvousSignalingCipher(key: key, localDirection: .largerKey, day: 1, sessionID: sid)
        // Hand-forge a correctly-authenticated frame with counter UInt64.max.
        let nonce = try ChaChaPoly.Nonce(data: RendezvousSignalingCrypto.nonceBytes(direction: .smallerKey, counter: .max))
        let box = try ChaChaPoly.seal(Data("x".utf8), using: key, nonce: nonce,
                                      authenticating: RendezvousSignalingCrypto.aad(day: 1, sessionID: sid, direction: .smallerKey))
        let wire = Data(repeating: 0xFF, count: 8) + box.ciphertext + box.tag
        XCTAssertThrowsError(try r.open(wire)) {
            XCTAssertEqual($0 as? RendezvousSignalingError, .invalidCounter)
        }
    }

    // MARK: - Per-session key (fix round 1, CRITICAL 1)

    func testSessionKeyKnownAnswer() throws {
        // Python reference: HKDF-SHA256(ikm=signalingKey, salt=sessionID,
        // info="rv-sig-session-v1" || UInt64BE(day)), L=32.
        let sig = SymmetricKey(data: Data(hex: "1fca3ce9b667206eaf3f77f88fce8f1da2cf565c938c57aeaa730586c6f413ef"))
        let sk = RendezvousSignalingCrypto.sessionKey(signalingKey: sig, sessionID: Data(0..<16), day: 20000)
        XCTAssertEqual(sk.rawData.hexString, "a8b3e158d47abdf29e0b5e2c2a01ddcc2b0d7e563b147810bddab58ca19a9bba")
    }

    func testSealedFrameKnownAnswer() throws {
        // Independent Python `cryptography` ChaCha20Poly1305 reference with the
        // documented nonce/AAD layout. Pins key derivation, nonce prefix, AAD
        // (incl. the SENDER's direction byte) and wire order.
        let sig = SymmetricKey(data: Data(hex: "1fca3ce9b667206eaf3f77f88fce8f1da2cf565c938c57aeaa730586c6f413ef"))
        let sid = Data(0..<16)
        let small = try RendezvousSignalingCipher(key: sig, localDirection: .smallerKey, day: 20000, sessionID: sid)
        XCTAssertEqual(try small.seal(Data("offer".utf8)).hexString,
                       "0000000000000000a3fd2658082270f310c61943b1cbe48784048358d9")
        let large = try RendezvousSignalingCipher(key: sig, localDirection: .largerKey, day: 20000, sessionID: sid,
                                                  initialSendCounter: 5)
        let w = try large.seal(Data("offer".utf8))
        XCTAssertEqual(w.hexString, "00000000000000052fdba8f1d162177da97befede3396960c8d2d228f2")
        XCTAssertEqual(try small.open(w), Data("offer".utf8))
    }

    func testRehandshakeSameDaySamePlaintextGivesDifferentCiphertext() throws {
        // Would catch dropping the sessionID from the key: same key + same
        // nonce (counter 0) would give identical bodies (two-time pad).
        let a = RendezvousTestIdentity(), b = RendezvousTestIdentity()
        let pa = IdentityRendezvousSecretProvider(identity: a), pb = IdentityRendezvousSecretProvider(identity: b)
        var bodies: [Data] = []
        for _ in 0..<2 {
            let ha = try RendezvousSignalingHandshake(provider: pa, peerKey: b.raw, day: day)
            let hb = try RendezvousSignalingHandshake(provider: pb, peerKey: a.raw, day: day)
            let ca = try ha.accept(peerHelloFrame: hb.helloFrame)
            let w = try ca.seal(Data("identical plaintext".utf8))
            XCTAssertEqual(Array(w.prefix(8)), [0, 0, 0, 0, 0, 0, 0, 0])
            // Ciphertext only (no tag): the tag differs anyway because the
            // sessionID is in the AAD; the keystream XOR is what must differ.
            bodies.append(Data(w.dropFirst(8).dropLast(16)))
        }
        XCTAssertEqual(bodies[0].count, 19)
        XCTAssertNotEqual(bodies[0], bodies[1], "same key+nonce across sessions (two-time pad)")
    }

    func testFramesFromOneSessionDoNotOpenInAnother() throws {
        // Same identities, two sessions on the same day.
        let a = RendezvousTestIdentity(), b = RendezvousTestIdentity()
        let pa = IdentityRendezvousSecretProvider(identity: a), pb = IdentityRendezvousSecretProvider(identity: b)
        func session() throws -> (RendezvousSignalingCipher, RendezvousSignalingCipher) {
            let ha = try RendezvousSignalingHandshake(provider: pa, peerKey: b.raw, day: day)
            let hb = try RendezvousSignalingHandshake(provider: pb, peerKey: a.raw, day: day)
            return (try ha.accept(peerHelloFrame: hb.helloFrame), try hb.accept(peerHelloFrame: ha.helloFrame))
        }
        let (a1, b1) = try session()
        let (a2, b2) = try session()
        let f1 = try a1.seal(Data("x".utf8))
        let f2 = try a2.seal(Data("x".utf8))
        XCTAssertThrowsError(try b2.open(f1)) { XCTAssertEqual($0 as? RendezvousSignalingError, .authenticationFailed) }
        XCTAssertThrowsError(try b1.open(f2)) { XCTAssertEqual($0 as? RendezvousSignalingError, .authenticationFailed) }
        XCTAssertNoThrow(try b1.open(f1))
        XCTAssertNoThrow(try b2.open(f2))
    }

    func testAADUsesSenderDirectionByte() throws {
        // A frame whose AAD carries the RECEIVER's direction (swapped) must fail.
        let sig = SymmetricKey(size: .bits256), sid = Data(repeating: 3, count: 16)
        let receiver = try RendezvousSignalingCipher(key: sig, localDirection: .largerKey, day: 9, sessionID: sid)
        let sk = RendezvousSignalingCrypto.sessionKey(signalingKey: sig, sessionID: sid, day: 9)
        func forge(aadDirection: UInt8) throws -> Data {
            let nonce = try ChaChaPoly.Nonce(data: Data([0, 0, 0, 0x01, 0, 0, 0, 0, 0, 0, 0, 1]))
            let aad = Data("rv-sig-v1".utf8) + Data([0, 0, 0, 0, 0, 0, 0, 9]) + sid + Data([aadDirection])
            let box = try ChaChaPoly.seal(Data("m".utf8), using: sk, nonce: nonce, authenticating: aad)
            return Data([0, 0, 0, 0, 0, 0, 0, 1]) + box.ciphertext + box.tag
        }
        XCTAssertThrowsError(try receiver.open(try forge(aadDirection: 0x02)))
        XCTAssertEqual(try receiver.open(try forge(aadDirection: 0x01)), Data("m".utf8))
    }

    func testConcurrentSealsUseUniqueCountersAndAllOpen() throws {
        let (alice, bob, _, _) = try connectedPair()
        let n = 2000
        let lock = NSLock()
        var frames: [Data] = []
        DispatchQueue.concurrentPerform(iterations: n) { i in
            let w = try! alice.seal(Data("frame \(i)".utf8))
            lock.lock(); frames.append(w); lock.unlock()
        }
        func counter(_ w: Data) -> UInt64 { w.prefix(8).reduce(0) { ($0 << 8) | UInt64($1) } }
        let counters = frames.map(counter)
        XCTAssertEqual(Set(counters).count, n)
        XCTAssertEqual(Set(counters), Set((0..<UInt64(n))))
        for w in frames.sorted(by: { counter($0) < counter($1) }) {
            XCTAssertNoThrow(try bob.open(w))
        }
    }

    func testReferenceSemanticsPreventNonceReuse() throws {
        let (alice, _, _, _) = try connectedPair()
        let alias = alice
        let w0 = try alice.seal(Data("a".utf8))
        let w1 = try alias.seal(Data("b".utf8))
        XCTAssertNotEqual(w0.prefix(8), w1.prefix(8))
    }
}

extension Data {
    init(hex: String) {
        var d = Data()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            d.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        self = d
    }
}
