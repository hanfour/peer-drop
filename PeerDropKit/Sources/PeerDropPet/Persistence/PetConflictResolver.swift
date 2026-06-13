import Foundation

/// Pure, deterministic merge of a local pet against a cloud pet for
/// cross-device sync. Single-pet model (`pet.json` is one file), so a
/// conflict always resolves to exactly one winner — there is no field-level
/// merge.
///
/// Two cases:
///
/// 1. **Same `id`** — the *same* pet edited on two devices. The most
///    recently *written* copy wins (`updatedAt`), with experience as the
///    tie-breaker for the rare equal-timestamp case. This is last-writer-wins
///    on a single identity and is always safe: nothing is "lost" beyond the
///    older edit it was always going to replace.
///
/// 2. **Different `id`** — two *distinct* pets, one per device, that have
///    never been reconciled (the pre-sync world, where each device spawned
///    its own `.newEgg()`). Enabling sync forces them to converge to one.
///    Picking the most-recently-written copy here would be destructive: a
///    device that just launched with a throwaway fresh baby would clobber an
///    established pet on the other device. Instead we keep the **more
///    invested** pet — higher level, then higher XP, then more interactions,
///    then the older (earlier-born) pet, then newest write as a last resort.
///    The loser is discarded; this is inherent to a single-pet design and is
///    documented as the cost of turning sync on.
public enum PetConflictResolver {

    public static func resolve(local: PetState, cloud: PetState) -> PetState {
        if local.id == cloud.id {
            return sameIdentityWinner(local: local, cloud: cloud)
        }
        return moreInvested(local, cloud)
    }

    /// Same pet on two devices → newest write wins (XP tie-break).
    private static func sameIdentityWinner(local: PetState, cloud: PetState) -> PetState {
        if local.updatedAt != cloud.updatedAt {
            return local.updatedAt > cloud.updatedAt ? local : cloud
        }
        return local.experience >= cloud.experience ? local : cloud
    }

    /// Distinct pets → keep the one the user has invested more into.
    /// Returns `a` on a total tie so the result is deterministic.
    private static func moreInvested(_ a: PetState, _ b: PetState) -> PetState {
        if a.level.rawValue != b.level.rawValue {
            return a.level.rawValue > b.level.rawValue ? a : b
        }
        if a.experience != b.experience {
            return a.experience > b.experience ? a : b
        }
        if a.stats.totalInteractions != b.stats.totalInteractions {
            return a.stats.totalInteractions > b.stats.totalInteractions ? a : b
        }
        if a.birthDate != b.birthDate {
            // Older pet (earlier birthDate) is the more-established one.
            return a.birthDate < b.birthDate ? a : b
        }
        if a.updatedAt != b.updatedAt {
            return a.updatedAt > b.updatedAt ? a : b
        }
        return a
    }
}
