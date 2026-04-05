import XCTest
@testable import PeerDrop

@MainActor
final class PetStoreTests: XCTestCase {
    var store: PetStore!
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        store = PetStore(directory: tempDir)
    }

    override func tearDown() {
        try? store.deleteAll()
        store = nil
        tempDir = nil
        super.tearDown()
    }

    func testSaveAndLoad() throws {
        let pet = PetState.newEgg()
        try store.save(pet)
        let loaded = try store.load()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.id, pet.id)
        XCTAssertEqual(loaded?.level, pet.level)
    }

    func testLoadReturnsNilWhenEmpty() throws {
        let loaded = try store.load()
        XCTAssertNil(loaded)
    }

    func testSaveEvolutionSnapshot() throws {
        let pet = PetState.newEgg()
        try store.saveEvolutionSnapshot(pet)
        let snapshots = try store.loadSnapshots()
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.id, pet.id)
    }

    func testOverwriteExistingPet() throws {
        var pet = PetState.newEgg()
        try store.save(pet)

        pet.experience = 999
        try store.save(pet)

        let loaded = try store.load()
        XCTAssertEqual(loaded?.experience, 999)
    }
}
