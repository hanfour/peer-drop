import XCTest
@testable import PeerDropSecurity

final class PreKeyStoreProperties: XCTestCase {

    func test_property_pruned_entries_are_always_expired() {
        PropertyTest.forAll(trials: 100, seed: 41) { rng in
            var state = PreKeyStore.emptyStateForTesting()
            let now = Date()
            let policy = SecurityPolicy.bundledDefault   // pruneWindow = 90

            // Seed the consumed map with random ages 0..200 days.
            for i in 0..<200 {
                let ageDays = Int(rng.next() % 200)
                let consumedAt = now.addingTimeInterval(-Double(ageDays) * 86400)
                state = withConsumed(state, id: UInt32(i), at: consumedAt)
            }

            _ = PreKeyStore.pruneConsumedOPK(in: &state, now: now, policy: policy)

            // Every surviving entry must be no older than the prune window.
            let cutoff = now.addingTimeInterval(-Double(policy.consumedOPKPruneWindowDays) * 86400)
            return state.consumedOneTimePreKeyIds?.allSatisfy { $0.value >= cutoff } ?? true
        }
    }

    func test_property_no_fresh_entries_pruned() {
        PropertyTest.forAll(trials: 100, seed: 42) { rng in
            var state = PreKeyStore.emptyStateForTesting()
            let now = Date()
            let policy = SecurityPolicy.bundledDefault
            let windowSeconds = Double(policy.consumedOPKPruneWindowDays) * 86400

            // Seed only with FRESH entries (strictly inside the window).
            for i in 0..<100 {
                let ageSeconds = Double(rng.next() % UInt64(windowSeconds))
                state = withConsumed(state, id: UInt32(i), at: now.addingTimeInterval(-ageSeconds))
            }
            let beforeCount = state.consumedOneTimePreKeyIds?.count ?? 0
            _ = PreKeyStore.pruneConsumedOPK(in: &state, now: now, policy: policy)
            return state.consumedOneTimePreKeyIds?.count == beforeCount
        }
    }

    func test_property_pruneWindow_always_geq_spkMaxAge_x4_for_bundledDefault() {
        // Spot-check the shipped policy — no randomness needed. The general
        // cross-field invariant is already pinned in SecurityPolicyTests; this
        // restates it from PreKeyStore's perspective so a future bundled-default
        // change that violates the margin lights up here as well.
        let p = SecurityPolicy.bundledDefault
        XCTAssertGreaterThanOrEqual(
            p.consumedOPKPruneWindowDays,
            p.spkMaxAgeDays * 4,
            "C4 prune window must outlive C1 SPK validity (×4 safety margin)"
        )
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
}
