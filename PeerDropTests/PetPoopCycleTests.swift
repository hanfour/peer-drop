import XCTest
@testable import PeerDrop

@MainActor
final class PetPoopCycleTests: XCTestCase {
    func testDigestingTransitionsToPooping() {
        var pet = PetState.newEgg()
        pet.level = .baby
        pet.lifeState = .digesting
        pet.digestEndTime = Date().addingTimeInterval(-1)
        let engine = PetEngine(pet: pet)
        engine.checkDigestion()
        XCTAssertEqual(engine.pet.lifeState, .pooping)
    }

    func testDigestingNotExpiredStays() {
        var pet = PetState.newEgg()
        pet.level = .baby
        pet.lifeState = .digesting
        pet.digestEndTime = Date().addingTimeInterval(3600)
        let engine = PetEngine(pet: pet)
        engine.checkDigestion()
        XCTAssertEqual(engine.pet.lifeState, .digesting)
    }

    func testFinishPoopingDropsPoop() {
        var pet = PetState.newEgg()
        pet.level = .baby
        pet.lifeState = .pooping
        let engine = PetEngine(pet: pet)
        engine.finishPooping()
        XCTAssertEqual(engine.pet.lifeState, .idle)
        XCTAssertEqual(engine.poopState.poops.count, 1)
    }

    func testCleanPoopIncrementsStat() {
        var pet = PetState.newEgg()
        pet.level = .baby
        let engine = PetEngine(pet: pet)
        engine.poopState.drop(at: CGPoint(x: 100, y: 700))
        let id = engine.poopState.poops.first!.id
        engine.cleanPoop(id: id)
        XCTAssertEqual(engine.pet.stats.poopsCleaned, 1)
    }
}
