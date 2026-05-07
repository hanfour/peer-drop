import XCTest
@testable import PeerDrop

final class PetDialogEngineTests: XCTestCase {

    private var engine: PetDialogEngine!

    override func setUp() {
        super.setUp()
        engine = PetDialogEngine()
    }

    // MARK: - generate()

    func testBabyReturnsText() {
        let result = engine.generate(level: .baby, mood: .happy)
        XCTAssertNotNil(result)
        XCTAssertFalse(result!.isEmpty)
    }

    func testBabyAllMoodsHaveDialogue() {
        for mood in PetMood.allCases {
            let result = engine.generate(level: .baby, mood: mood)
            XCTAssertNotNil(result, "Baby should produce dialogue for mood \(mood)")
            XCTAssertFalse(result!.isEmpty, "Dialogue should not be empty for mood \(mood)")
        }
    }

    // MARK: - generatePrivateChat()

    func testGeneratePrivateChat() {
        // Run multiple times to cover the 50 % third-line branch
        for _ in 0..<20 {
            let lines = engine.generatePrivateChat(
                myLevel: .baby, partnerLevel: .baby,
                myMood: .happy, partnerMood: .curious
            )
            XCTAssertGreaterThanOrEqual(lines.count, 2,
                                        "Private chat must have at least 2 lines")
            XCTAssertEqual(lines[0].speaker, "mine")
            XCTAssertEqual(lines[1].speaker, "partner")
            if lines.count == 3 {
                XCTAssertEqual(lines[2].speaker, "mine")
            }
        }
    }

}
