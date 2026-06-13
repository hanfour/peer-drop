import Foundation
import os

private let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "PetSyncCoordinator")

/// The cloud surface the coordinator depends on. `PetCloudSync` is the real
/// implementation; tests inject a fake so the merge/push orchestration can be
/// exercised without an iCloud container.
public protocol PetCloudSyncing: AnyObject {
    func loadAndMigrateFromCloud() throws -> PetState?
    func syncFullState(_ pet: PetState) throws
    func syncMetadata(_ pet: PetState)
    func observeCloudChanges(onUpdate: @escaping (PetState) -> Void)
}

extension PetCloudSync: PetCloudSyncing {}

/// Orchestrates local ⇄ iCloud pet sync on top of `PetStore` (local truth) and
/// `PetCloudSyncing` (cloud transport), using `PetConflictResolver` to merge.
///
/// Before this existed, iOS only ever *pushed* to iCloud and never read it
/// back, and the Mac didn't touch iCloud at all — so the two platforms could
/// never show the same pet. This wires the read-and-merge launch path plus a
/// push helper and a live-change observer, all platform-agnostic. On a device
/// without an iCloud container (e.g. macOS before the entitlement/provisioning
/// is in place) every cloud call no-ops and the coordinator degrades to plain
/// local persistence.
public final class PetSyncCoordinator {
    private let local: PetStore
    private let cloud: PetCloudSyncing

    public init(local: PetStore = PetStore(), cloud: PetCloudSyncing = PetCloudSync()) {
        self.local = local
        self.cloud = cloud
    }

    /// The authoritative pet to show at launch. Loads + migrates both the
    /// local and cloud copies, merges them via `PetConflictResolver`, persists
    /// the winner locally (so the device adopts a cloud-won pet), and returns
    /// it. Returns nil only when neither side has a pet (true first launch).
    @discardableResult
    public func resolvedLaunchPet(defaults: UserDefaults = .standard) -> PetState? {
        let localPet = try? local.loadAndMigrate(defaults: defaults)
        let cloudPet = try? cloud.loadAndMigrateFromCloud()

        switch (localPet, cloudPet) {
        case let (l?, c?):
            let winner = PetConflictResolver.resolve(local: l, cloud: c)
            // Persist locally whenever the cloud copy won (different bytes), so
            // the adopted pet survives the next cold launch even offline.
            if winner.id != l.id || winner.updatedAt != l.updatedAt {
                try? local.save(winner)
                logger.debug("Launch merge: adopted cloud-won pet \(winner.id)")
            }
            return winner
        case let (l?, nil):
            return l
        case let (nil, c?):
            // Nothing local yet — adopt the cloud pet and persist it.
            try? local.save(c)
            logger.debug("Launch merge: seeded local from cloud pet \(c.id)")
            return c
        case (nil, nil):
            return nil
        }
    }

    /// Persist `pet` everywhere: local first (always), then push to iCloud
    /// (best-effort). `syncMetadata` bumps iCloud KVS, which is what fires the
    /// *other* device's `observeCloudChanges` so it knows to re-read the
    /// Documents file `syncFullState` just wrote.
    public func push(_ pet: PetState) {
        try? local.save(pet)
        do {
            try cloud.syncFullState(pet)
            cloud.syncMetadata(pet)
        } catch {
            logger.error("push: cloud sync failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Observe live iCloud changes from other devices. `currentLocal` supplies
    /// the in-memory pet to merge the incoming cloud pet against; `onResolved`
    /// receives the winner (already persisted locally) on the main queue.
    public func observe(
        currentLocal: @escaping () -> PetState?,
        onResolved: @escaping (PetState) -> Void
    ) {
        cloud.observeCloudChanges { [weak self] cloudPet in
            guard let self else { return }
            let winner: PetState
            if let l = currentLocal() {
                winner = PetConflictResolver.resolve(local: l, cloud: cloudPet)
            } else {
                winner = cloudPet
            }
            try? self.local.save(winner)
            onResolved(winner)
        }
    }
}
