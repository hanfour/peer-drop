import XCTest
import CryptoKit
@testable import PeerDrop

final class RatchetProperties: XCTestCase {

    func test_property_skippedKeys_neverExceedMaxCount_afterLRU() throws {
        PropertyTest.forAll(trials: 50, seed: 31) { rng in
            do {
                let session = try freshSession(seed: rng.next())
                let policy = SecurityPolicy.bundledDefault
                // Insert many entries with varying timestamps to force LRU.
                let now = Date()
                for i in 0..<500 {
                    session.setSkippedKeyForTesting(
                        ratchetKey: Data([UInt8(rng.next() & 0xFF), UInt8(i & 0xFF)]),
                        counter: UInt32(i),
                        entry: .init(
                            key: SymmetricKey(size: .bits256),
                            createdAt: now.addingTimeInterval(-Double(rng.next() % 10000))
                        )
                    )
                }
                _ = session.evictLRUSkippedKeys(policy: policy)
                return session.skippedKeysCountForTesting <= policy.skippedKeyMaxCount
            } catch {
                return false
            }
        }
    }

    func test_property_expiredSkippedKeys_alwaysEvicted() throws {
        PropertyTest.forAll(trials: 50, seed: 32) { rng in
            do {
                let session = try freshSession(seed: rng.next())
                let policy = SecurityPolicy.bundledDefault
                let ttlSeconds = Double(policy.skippedKeyTTLDays) * 86400
                let now = Date()
                let staleAge = ttlSeconds + Double(rng.next() % 86400) + 1
                session.setSkippedKeyForTesting(
                    ratchetKey: Data([UInt8(rng.next() & 0xFF)]),
                    counter: 0,
                    entry: .init(key: SymmetricKey(size: .bits256),
                                 createdAt: now.addingTimeInterval(-staleAge))
                )
                _ = session.evictExpiredSkippedKeys(now: now, policy: policy)
                return session.skippedKeysCountForTesting == 0
            } catch {
                return false
            }
        }
    }

    func test_property_freshSkippedKeys_neverEvictedByTTL() throws {
        PropertyTest.forAll(trials: 50, seed: 33) { rng in
            do {
                let session = try freshSession(seed: rng.next())
                let policy = SecurityPolicy.bundledDefault
                let ttlSeconds = Double(policy.skippedKeyTTLDays) * 86400
                let now = Date()
                // Age strictly inside the TTL window.
                let freshAge = Double(rng.next() % UInt64(ttlSeconds))
                session.setSkippedKeyForTesting(
                    ratchetKey: Data([UInt8(rng.next() & 0xFF)]),
                    counter: 0,
                    entry: .init(key: SymmetricKey(size: .bits256),
                                 createdAt: now.addingTimeInterval(-freshAge))
                )
                _ = session.evictExpiredSkippedKeys(now: now, policy: policy)
                return session.skippedKeysCountForTesting == 1
            } catch {
                return false
            }
        }
    }

    // Build a fresh DoubleRatchetSession from a seed for repeatable trials.
    private func freshSession(seed: UInt64) throws -> DoubleRatchetSession {
        var seedBytes = Data(count: 32)
        seedBytes.withUnsafeMutableBytes { ptr in
            let buf = ptr.bindMemory(to: UInt64.self)
            buf[0] = seed
        }
        let rootKey = SymmetricKey(data: SHA256.hash(data: seedBytes))
        let bobRatchetKey = DeterministicCrypto.curve25519AgreementKey(seed: seedBytes)
        return try DoubleRatchetSession.initializeAsResponder(
            rootKey: rootKey,
            myRatchetKey: bobRatchetKey
        )
    }
}
