import XCTest
@testable import PeerDropPet

final class PetConflictResolverTests: XCTestCase {

    private func makePet(
        id: UUID = UUID(),
        level: PetLevel = .baby,
        xp: Int = 0,
        interactions: Int = 0,
        birthDate: Date = Date(timeIntervalSince1970: 1_000_000),
        updatedAt: Date = Date(timeIntervalSince1970: 1_000_000)
    ) -> PetState {
        var stats = PetStats()
        stats.totalInteractions = interactions
        return PetState(
            id: id,
            birthDate: birthDate,
            level: level,
            experience: xp,
            genome: .random(),
            mood: .curious,
            socialLog: [],
            lastInteraction: updatedAt,
            stats: stats,
            updatedAt: updatedAt
        )
    }

    // MARK: - Same identity → newest write wins

    func testSameIdLocalNewerWins() {
        let id = UUID()
        let local = makePet(id: id, xp: 10, updatedAt: Date(timeIntervalSince1970: 2_000))
        let cloud = makePet(id: id, xp: 99, updatedAt: Date(timeIntervalSince1970: 1_000))
        // Newest write wins even though cloud has more XP — same pet, latest edit is authoritative.
        XCTAssertEqual(PetConflictResolver.resolve(local: local, cloud: cloud).id, id)
        XCTAssertEqual(PetConflictResolver.resolve(local: local, cloud: cloud).experience, 10)
    }

    func testSameIdCloudNewerWins() {
        let id = UUID()
        let local = makePet(id: id, xp: 50, updatedAt: Date(timeIntervalSince1970: 1_000))
        let cloud = makePet(id: id, xp: 5, updatedAt: Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(PetConflictResolver.resolve(local: local, cloud: cloud).experience, 5)
    }

    func testSameIdEqualTimestampHigherXpWins() {
        let id = UUID()
        let t = Date(timeIntervalSince1970: 1_500)
        let local = makePet(id: id, xp: 7, updatedAt: t)
        let cloud = makePet(id: id, xp: 42, updatedAt: t)
        XCTAssertEqual(PetConflictResolver.resolve(local: local, cloud: cloud).experience, 42)
    }

    // MARK: - Different identity → more-invested wins

    func testDifferentIdHigherLevelWins() {
        let local = makePet(level: .adult, xp: 0)
        let cloud = makePet(level: .baby, xp: 9999)
        // Level dominates XP: an adult outranks a baby regardless of XP.
        XCTAssertEqual(PetConflictResolver.resolve(local: local, cloud: cloud).level, .adult)
    }

    func testDifferentIdFreshBabyCannotClobberEstablishedPet() {
        // The critical regression guard: a device that just spawned a throwaway
        // baby (newest updatedAt) must NOT overwrite the established pet on the
        // other device when sync is first enabled.
        let establishedCloud = makePet(
            level: .adult, xp: 500, interactions: 120,
            birthDate: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 5_000)
        )
        let freshLocal = makePet(
            level: .baby, xp: 0, interactions: 0,
            birthDate: Date(timeIntervalSince1970: 9_999),
            updatedAt: Date(timeIntervalSince1970: 9_999)  // newest!
        )
        let winner = PetConflictResolver.resolve(local: freshLocal, cloud: establishedCloud)
        XCTAssertEqual(winner.id, establishedCloud.id)
        XCTAssertEqual(winner.level, .adult)
    }

    func testDifferentIdSameLevelHigherXpWins() {
        let local = makePet(level: .baby, xp: 30)
        let cloud = makePet(level: .baby, xp: 80)
        XCTAssertEqual(PetConflictResolver.resolve(local: local, cloud: cloud).experience, 80)
    }

    func testDifferentIdSameLevelSameXpMoreInteractionsWins() {
        let local = makePet(level: .baby, xp: 30, interactions: 3)
        let cloud = makePet(level: .baby, xp: 30, interactions: 50)
        XCTAssertEqual(
            PetConflictResolver.resolve(local: local, cloud: cloud).stats.totalInteractions, 50
        )
    }

    func testDifferentIdTotalTieIsDeterministic() {
        let local = makePet(level: .baby, xp: 1, interactions: 1,
                            birthDate: Date(timeIntervalSince1970: 1),
                            updatedAt: Date(timeIntervalSince1970: 1))
        let cloud = makePet(level: .baby, xp: 1, interactions: 1,
                            birthDate: Date(timeIntervalSince1970: 1),
                            updatedAt: Date(timeIntervalSince1970: 1))
        // Total tie → returns local ("a") deterministically.
        XCTAssertEqual(PetConflictResolver.resolve(local: local, cloud: cloud).id, local.id)
    }
}
