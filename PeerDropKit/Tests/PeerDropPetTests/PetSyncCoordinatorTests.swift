import XCTest
@testable import PeerDropPet

/// In-memory stand-in for the iCloud surface so the coordinator's
/// load/merge/persist/push orchestration can run without an iCloud container.
private final class FakePetCloud: PetCloudSyncing {
    var cloudPet: PetState?
    private(set) var syncedFull: [PetState] = []
    private(set) var syncedMetadata: [PetState] = []
    private var observer: ((PetState) -> Void)?

    func loadAndMigrateFromCloud() throws -> PetState? { cloudPet }
    func syncFullState(_ pet: PetState) throws { syncedFull.append(pet); cloudPet = pet }
    func syncMetadata(_ pet: PetState) { syncedMetadata.append(pet) }
    func observeCloudChanges(onUpdate: @escaping (PetState) -> Void) { observer = onUpdate }

    /// Simulate another device pushing a change.
    func emitRemoteChange(_ pet: PetState) { observer?(pet) }
}

final class PetSyncCoordinatorTests: XCTestCase {
    private var tempDir: URL!
    private var store: PetStore!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = PetStore(directory: tempDir)
    }

    override func tearDown() {
        try? store.deleteAll()
        store = nil; tempDir = nil
        super.tearDown()
    }

    private func makePet(id: UUID = UUID(), level: PetLevel = .baby, xp: Int = 0,
                         updatedAt: Date = Date(timeIntervalSince1970: 1_000)) -> PetState {
        PetState(id: id, birthDate: Date(timeIntervalSince1970: 1_000), level: level,
                 experience: xp, genome: .random(), mood: .curious, socialLog: [],
                 lastInteraction: updatedAt, updatedAt: updatedAt)
    }

    // MARK: - resolvedLaunchPet

    func testLaunchNeitherReturnsNil() {
        let cloud = FakePetCloud()
        let coord = PetSyncCoordinator(local: store, cloud: cloud)
        XCTAssertNil(coord.resolvedLaunchPet())
    }

    func testLaunchLocalOnlyReturnsLocal() throws {
        let local = makePet(xp: 42)
        try store.save(local)
        let coord = PetSyncCoordinator(local: store, cloud: FakePetCloud())
        XCTAssertEqual(coord.resolvedLaunchPet()?.id, local.id)
    }

    func testLaunchCloudOnlySeedsLocal() throws {
        let cloud = FakePetCloud()
        cloud.cloudPet = makePet(xp: 7)
        let coord = PetSyncCoordinator(local: store, cloud: cloud)
        let winner = coord.resolvedLaunchPet()
        XCTAssertEqual(winner?.id, cloud.cloudPet?.id)
        // Seeded locally → a subsequent local load finds it.
        XCTAssertEqual(try store.load()?.id, cloud.cloudPet?.id)
    }

    func testLaunchSameIdCloudNewerWinsAndPersists() throws {
        // PetStore.save() stamps updatedAt = now (real write time), so to model
        // "another device wrote more recently than this device's last save" the
        // cloud copy must carry a timestamp in the future relative to the save.
        let id = UUID()
        try store.save(makePet(id: id, xp: 5))
        let cloud = FakePetCloud()
        cloud.cloudPet = makePet(id: id, xp: 88, updatedAt: Date(timeIntervalSinceNow: 3_600))
        let coord = PetSyncCoordinator(local: store, cloud: cloud)
        let winner = coord.resolvedLaunchPet()
        XCTAssertEqual(winner?.experience, 88)
        XCTAssertEqual(try store.load()?.experience, 88, "cloud-won pet must be persisted locally")
    }

    func testLaunchDifferentIdMoreInvestedCloudWins() throws {
        // Local fresh baby, cloud established adult → adult wins, gets adopted.
        try store.save(makePet(level: .baby, xp: 0, updatedAt: Date(timeIntervalSince1970: 9_999)))
        let cloud = FakePetCloud()
        let adult = makePet(level: .adult, xp: 300, updatedAt: Date(timeIntervalSince1970: 2_000))
        cloud.cloudPet = adult
        let coord = PetSyncCoordinator(local: store, cloud: cloud)
        XCTAssertEqual(coord.resolvedLaunchPet()?.id, adult.id)
        XCTAssertEqual(try store.load()?.level, .adult)
    }

    // MARK: - push

    func testPushSavesLocallyAndSyncsBoth() throws {
        let cloud = FakePetCloud()
        let coord = PetSyncCoordinator(local: store, cloud: cloud)
        let pet = makePet(xp: 11)
        coord.push(pet)
        XCTAssertEqual(try store.load()?.id, pet.id, "push must persist locally")
        XCTAssertEqual(cloud.syncedFull.count, 1, "push must sync full state")
        XCTAssertEqual(cloud.syncedMetadata.count, 1, "push must bump KVS metadata to wake other devices")
    }

    // MARK: - observe

    func testObserveMergesRemoteChangeAgainstLocal() throws {
        let id = UUID()
        let localPet = makePet(id: id, xp: 5, updatedAt: Date(timeIntervalSince1970: 1_000))
        try store.save(localPet)
        let cloud = FakePetCloud()
        let coord = PetSyncCoordinator(local: store, cloud: cloud)

        var resolved: PetState?
        coord.observe(currentLocal: { localPet }, onResolved: { resolved = $0 })

        // Remote device pushes a newer edit of the SAME pet.
        let remote = makePet(id: id, xp: 77, updatedAt: Date(timeIntervalSince1970: 9_000))
        cloud.emitRemoteChange(remote)

        XCTAssertEqual(resolved?.experience, 77, "newer remote edit of same pet should win")
        XCTAssertEqual(try store.load()?.experience, 77, "merged winner must be persisted")
    }
}
