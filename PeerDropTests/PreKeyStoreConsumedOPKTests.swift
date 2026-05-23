import XCTest
@testable import PeerDrop

/// Tests for Task 3.7: consumedOneTimePreKeyIds migrated to [UInt32: Date].
/// Covers:
///   1. Consuming an OTP records a fresh timestamp.
///   2. Legacy on-disk format (JSON array of UInt32) deserialises to [UInt32: Date]
///      with each entry given a fresh Date().
///   3. New v5.4+ format (JSON object) round-trips correctly.
final class PreKeyStoreConsumedOPKTests: XCTestCase {

    private func makeStorageKey() -> String { "test-consumed-opk-\(UUID().uuidString)" }

    private func cleanup(_ key: String) {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Security", isDirectory: true)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(key).enc"))
    }

    // MARK: - Test 1: consume sets a fresh timestamp

    func test_consumedOPK_stores_with_timestamp() throws {
        let key = makeStorageKey()
        defer { cleanup(key) }

        let store = PreKeyStore(storageKey: key)
        store.flush()  // flush initial debounced save

        let bundle = store.generatePreKeyBundle()
        let targetId = bundle.oneTimePreKeys.first!.id

        let before = Date()
        let consumed = try store.consumeOneTimePreKey(id: targetId)
        let after = Date()

        XCTAssertNotNil(consumed, "consumeOneTimePreKey should return the key")

        let snap = store.snapshotForTesting()
        guard let consumedAt = snap.consumedOneTimePreKeyIds?[targetId] else {
            XCTFail("consumedOneTimePreKeyIds should contain the consumed id \(targetId)")
            return
        }
        XCTAssertGreaterThanOrEqual(consumedAt, before, "timestamp must be >= time before consume")
        XCTAssertLessThanOrEqual(consumedAt, after, "timestamp must be <= time after consume")
        XCTAssertLessThan(abs(consumedAt.timeIntervalSinceNow), 5.0, "timestamp must be recent (within 5s)")
    }

    // MARK: - Test 2: legacy array format decodes to [UInt32: Date] with fresh timestamps

    func test_legacy_consumed_set_deserializes_with_freshTimestamps() throws {
        // Build a fresh store to extract a real PersistedSignedPreKey JSON shape
        // (avoids hard-coding the exact Codable encoding of CryptoKit keys).
        let key = makeStorageKey()
        defer { cleanup(key) }

        let freshStore = PreKeyStore(storageKey: key)
        freshStore.flush()
        let freshSnap = freshStore.snapshotForTesting()

        // Re-encode the fresh state's currentSignedPreKey + other fields to a
        // dictionary, then inject the legacy-format consumedOneTimePreKeyIds array.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let encodedSignedKey = try encoder.encode(freshSnap.currentSignedPreKey)
        let signedKeyObj = try JSONSerialization.jsonObject(with: encodedSignedKey)

        // Build a legacy-shaped JSON object (consumedOneTimePreKeyIds as array).
        var legacyDict: [String: Any] = [
            "currentSignedPreKey": signedKeyObj,
            "previousSignedPreKeys": [],
            "oneTimePreKeys": [],
            "nextOneTimePreKeyId": 100,
            "nextSignedPreKeyId": 1,
            "consumedOneTimePreKeyIds": [1, 2, 3]  // legacy array format
        ]
        let legacyJSON = try JSONSerialization.data(withJSONObject: legacyDict)

        let before = Date()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let state = try PreKeyStore.decodeStateForTesting(from: legacyJSON)
        let after = Date()

        XCTAssertNotNil(state.consumedOneTimePreKeyIds, "consumedOneTimePreKeyIds must be decoded")
        XCTAssertEqual(state.consumedOneTimePreKeyIds?.count, 3, "should have 3 legacy entries")

        guard let ids = state.consumedOneTimePreKeyIds else { return }
        XCTAssertNotNil(ids[1], "id 1 should be present")
        XCTAssertNotNil(ids[2], "id 2 should be present")
        XCTAssertNotNil(ids[3], "id 3 should be present")

        for (_, when) in ids {
            XCTAssertGreaterThanOrEqual(when, before.addingTimeInterval(-1),
                "legacy entry timestamp must be near now (lower bound)")
            XCTAssertLessThanOrEqual(when, after.addingTimeInterval(1),
                "legacy entry timestamp must be near now (upper bound)")
            XCTAssertLessThan(abs(when.timeIntervalSinceNow), 5.0,
                "legacy entry should get a fresh timestamp (within 5s of now)")
        }
    }

    // MARK: - Test 3: v3.3-era format (absent field) decodes as nil / treated as empty

    func test_v33_era_absent_field_decodes_as_nil() throws {
        let key = makeStorageKey()
        defer { cleanup(key) }

        let freshStore = PreKeyStore(storageKey: key)
        freshStore.flush()
        let freshSnap = freshStore.snapshotForTesting()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let encodedSignedKey = try encoder.encode(freshSnap.currentSignedPreKey)
        let signedKeyObj = try JSONSerialization.jsonObject(with: encodedSignedKey)

        // No consumedOneTimePreKeyIds key at all — v3.3-era format.
        let legacyDict: [String: Any] = [
            "currentSignedPreKey": signedKeyObj,
            "previousSignedPreKeys": [],
            "oneTimePreKeys": [],
            "nextOneTimePreKeyId": 100,
            "nextSignedPreKeyId": 1
        ]
        let legacyJSON = try JSONSerialization.data(withJSONObject: legacyDict)
        let state = try PreKeyStore.decodeStateForTesting(from: legacyJSON)

        // nil is the sentinel: init treats it as empty
        XCTAssertNil(state.consumedOneTimePreKeyIds,
            "absent consumedOneTimePreKeyIds should decode as nil")
    }

    // MARK: - Test 4: new v5.4+ format round-trips

    func test_new_format_roundTrips() throws {
        let key = makeStorageKey()
        defer { cleanup(key) }

        let store = PreKeyStore(storageKey: key)
        store.flush()

        let bundle = store.generatePreKeyBundle()
        let id1 = bundle.oneTimePreKeys[0].id
        let id2 = bundle.oneTimePreKeys[1].id

        _ = try store.consumeOneTimePreKey(id: id1)
        _ = try store.consumeOneTimePreKey(id: id2)

        let snap1 = store.snapshotForTesting()
        guard let consumed1 = snap1.consumedOneTimePreKeyIds else {
            XCTFail("consumedOneTimePreKeyIds should not be nil after consuming")
            return
        }
        XCTAssertNotNil(consumed1[id1])
        XCTAssertNotNil(consumed1[id2])

        // Flush and reload — verify the new format round-trips through disk.
        store.flush()
        let store2 = PreKeyStore(storageKey: key)
        let snap2 = store2.snapshotForTesting()
        guard let consumed2 = snap2.consumedOneTimePreKeyIds else {
            XCTFail("consumedOneTimePreKeyIds should survive a flush+reload round-trip")
            return
        }
        XCTAssertNotNil(consumed2[id1], "id1 should survive round-trip")
        XCTAssertNotNil(consumed2[id2], "id2 should survive round-trip")

        // Timestamps survive round-trip within 1s tolerance (Date encoding rounds
        // to nearest second with .secondsSince1970 — but JSONEncoder default is
        // .deferredToDate which encodes as a Double with sub-second precision,
        // so tolerance can be tighter; use 1s to be safe).
        if let t1a = consumed1[id1], let t1b = consumed2[id1] {
            XCTAssertLessThan(abs(t1a.timeIntervalSince(t1b)), 1.0,
                "timestamp for id1 must survive round-trip within 1s")
        }
    }

    // MARK: - Test 6: pruneConsumedOPK removes expired entries (Task 3.8)

    func test_prune_removes_expired_entries() {
        var state = PreKeyStore.emptyStateForTesting()
        let now = Date()
        // 100 days old → should be pruned (beyond 90-day window)
        state = withConsumed(state, id: 1, at: now.addingTimeInterval(-86400 * 100))
        // 30 days old → should be kept
        state = withConsumed(state, id: 2, at: now.addingTimeInterval(-86400 * 30))
        // fresh → should be kept
        state = withConsumed(state, id: 3, at: now)

        let policy = SecurityPolicy.bundledDefault  // consumedOPKPruneWindowDays = 90

        let prunedCount = PreKeyStore.pruneConsumedOPK(in: &state, now: now, policy: policy)
        XCTAssertEqual(prunedCount, 1, "exactly one entry (100 days old) should be pruned")
        XCTAssertNil(state.consumedOneTimePreKeyIds?[1], "100-day-old entry must be evicted")
        XCTAssertNotNil(state.consumedOneTimePreKeyIds?[2], "30-day-old entry must be kept")
        XCTAssertNotNil(state.consumedOneTimePreKeyIds?[3], "fresh entry must be kept")
    }

    // MARK: - Test 7: pruneConsumedOPK is a no-op when all entries are fresh (Task 3.8)

    func test_prune_noOp_whenAllFresh() {
        var state = PreKeyStore.emptyStateForTesting()
        let now = Date()
        state = withConsumed(state, id: 1, at: now.addingTimeInterval(-86400 * 30))
        state = withConsumed(state, id: 2, at: now)

        let policy = SecurityPolicy.bundledDefault
        let prunedCount = PreKeyStore.pruneConsumedOPK(in: &state, now: now, policy: policy)
        XCTAssertEqual(prunedCount, 0, "no entries should be pruned when all are within the window")
        XCTAssertEqual(state.consumedOneTimePreKeyIds?.count, 2,
            "both entries must survive the prune pass")
    }

    // MARK: - Helpers

    /// Returns a copy of `state` with `id` inserted into `consumedOneTimePreKeyIds` at `date`.
    /// Uses `PersistedState`'s full initialiser because the field is `let`.
    private func withConsumed(_ state: PreKeyStore.PersistedState, id: UInt32, at date: Date) -> PreKeyStore.PersistedState {
        var ids = state.consumedOneTimePreKeyIds ?? [:]
        ids[id] = date
        return PreKeyStore.PersistedState(
            currentSignedPreKey: state.currentSignedPreKey,
            previousSignedPreKeys: state.previousSignedPreKeys,
            oneTimePreKeys: state.oneTimePreKeys,
            nextOneTimePreKeyId: state.nextOneTimePreKeyId,
            nextSignedPreKeyId: state.nextSignedPreKeyId,
            consumedOneTimePreKeyIds: ids
        )
    }

    // MARK: - Test 5: double-consume still returns nil after migration

    func test_doubleConsume_stillRejectsAfterMigration() throws {
        let key = makeStorageKey()
        defer { cleanup(key) }

        let store = PreKeyStore(storageKey: key)
        let bundle = store.generatePreKeyBundle()
        let id = bundle.oneTimePreKeys.first!.id

        let first = try store.consumeOneTimePreKey(id: id)
        XCTAssertNotNil(first, "first consume should succeed")

        let second = try store.consumeOneTimePreKey(id: id)
        XCTAssertNil(second, "second consume must return nil — id is in consumedOneTimePreKeyIds")
    }
}
