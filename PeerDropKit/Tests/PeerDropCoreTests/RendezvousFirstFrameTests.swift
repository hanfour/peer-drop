import XCTest
@testable import PeerDropCore

final class RendezvousFirstFrameTests: XCTestCase {

    private let token = Data((0..<32).map { UInt8($0 &* 7) })
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testFirstFrameShapeAndSize() throws {
        let tags = RendezvousSessionTagStore(random: CountingRandom(seed: 0))
        let frame = try RendezvousFirstFrame.build(token: token, now: now, sessionTags: tags)
        XCTAssertLessThanOrEqual(frame.utf8.count, RendezvousFirstFrame.maxFrameBytes)
        XCTAssertFalse(frame.contains(" "))
        XCTAssertFalse(frame.contains("\n"))

        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])
        XCTAssertEqual(Set(obj.keys), ["v", "t", "pow", "s"])
        XCTAssertEqual(obj["v"] as? Int, 1)
        XCTAssertEqual(obj["t"] as? String, try RendezvousToken.encoded(token))
        let pow = try XCTUnwrap(obj["pow"] as? [String: Any])
        XCTAssertEqual(Set(pow.keys), ["h", "n"])
        let h = try XCTUnwrap(pow["h"] as? Int)
        let n = try XCTUnwrap(pow["n"] as? String)
        XCTAssertEqual(h, RendezvousProofOfWork.currentHour(now: now))
        // Exactly what the Worker would accept at `now`.
        XCTAssertTrue(RendezvousProofOfWork.verifyClaim(tokenBytes: token, hour: h, nonce: n, now: now))
        let s = try XCTUnwrap(obj["s"] as? String)
        XCTAssertEqual(s, "AAECAwQFBgcICQoLDA0ODw")  // 16 bytes 0x00..0x0F, canonical b64url
        XCTAssertEqual(s.count, 22)

        // Exact key order / compactness.
        XCTAssertTrue(frame.hasPrefix(#"{"v":1,"t":""#))
        XCTAssertTrue(frame.hasSuffix(#""s":"AAECAwQFBgcICQoLDA0ODw"}"#))
    }

    func testSharedInteropFixtureBuildsByteForByte() throws {
        // cloudflare-worker/test-vectors/rendezvous-first-frame.json is also
        // asserted by the Worker's vitest (verifyRendezvousClaim/parseSessionId).
        struct Fixture: Decodable {
            struct Expected: Decodable { let t: String; let h: Int; let n: String; let s: String }
            let nowSeconds: Int
            let frame: String
            let expected: Expected
        }
        let url = URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("cloudflare-worker/test-vectors/rendezvous-first-frame.json")
        guard let data = FileManager.default.contents(atPath: url.path) else {
            XCTFail("Shared first-frame fixture missing at \(url.path)")
            throw CocoaError(.fileNoSuchFile)
        }
        let fx = try JSONDecoder().decode(Fixture.self, from: data)
        let fixtureToken = Data((0..<32).map { UInt8(($0 * 7) % 256) })
        let built = try RendezvousFirstFrame.build(
            token: fixtureToken, now: Date(timeIntervalSince1970: TimeInterval(fx.nowSeconds)),
            sessionTags: RendezvousSessionTagStore(random: CountingRandom(seed: 0)))
        XCTAssertEqual(built, fx.frame)
        XCTAssertEqual(try RendezvousToken.encoded(fixtureToken), fx.expected.t)
        XCTAssertEqual(RendezvousProofOfWork.currentHour(now: Date(timeIntervalSince1970: TimeInterval(fx.nowSeconds))), fx.expected.h)
        XCTAssertTrue(RendezvousProofOfWork.verifyClaim(
            tokenBytes: fixtureToken, hour: fx.expected.h, nonce: fx.expected.n,
            now: Date(timeIntervalSince1970: TimeInterval(fx.nowSeconds))))
        XCTAssertEqual(fx.expected.s, "AAECAwQFBgcICQoLDA0ODw")
    }

    func testFirstFrameRejectsBadToken() {
        let tags = RendezvousSessionTagStore()
        XCTAssertThrowsError(try RendezvousFirstFrame.build(token: Data(count: 31), now: now, sessionTags: tags))
    }

    func testFirstFrameEscapesNonce() throws {
        let frame = try RendezvousFirstFrame.build(token: token, hour: 5, nonce: #"a"b\c"#, sessionTag: "AAECAwQFBgcICQoLDA0ODw")
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])
        XCTAssertEqual((obj["pow"] as? [String: Any])?["n"] as? String, #"a"b\c"#)
    }

    func testSessionTagStableForSameTokenWithinRun() {
        let tags = RendezvousSessionTagStore()
        let t1 = Data(repeating: 1, count: 32)
        let s1 = tags.tag(for: t1)
        XCTAssertEqual(tags.tag(for: t1), s1)  // reconnect after 2h cap reuses s
        XCTAssertEqual(RendezvousToken.decodeBase64URL(s1, expectedLength: 16)?.count, 16)
    }

    func testSessionTagNeverReusedAcrossTokens() {
        // Hostile RNG that keeps returning the same bytes: the store must still
        // never hand the same `s` to two tokens.
        final class StuckRandom: RendezvousRandomSource {
            var calls = 0
            func randomBytes(count: Int) -> Data {
                calls += 1
                return calls <= 3 ? Data(repeating: 0xAB, count: count) : Data(repeating: UInt8(calls), count: count)
            }
        }
        let rng = StuckRandom()
        let tags = RendezvousSessionTagStore(random: rng)
        let s1 = tags.tag(for: Data(repeating: 1, count: 32))
        let s2 = tags.tag(for: Data(repeating: 2, count: 32))
        XCTAssertNotEqual(s1, s2)
        var seen: Set<String> = [s1, s2]
        for i in 3..<50 {
            XCTAssertTrue(seen.insert(tags.tag(for: Data(repeating: UInt8(i), count: 32))).inserted)
        }
    }

    func testSessionTagFreshPerAppRun() {
        let t = Data(repeating: 1, count: 32)
        let run1 = RendezvousSessionTagStore()
        let run2 = RendezvousSessionTagStore()   // a new app run = a new store
        XCTAssertNotEqual(run1.tag(for: t), run2.tag(for: t))
    }

    func testForgetTokenIssuesNewTagAndNeverRecyclesOld() {
        let tags = RendezvousSessionTagStore()
        let t = Data(repeating: 1, count: 32)
        let s1 = tags.tag(for: t)
        tags.forget(tokens: [t])
        let s2 = tags.tag(for: t)
        XCTAssertNotEqual(s1, s2)
    }
}
