import XCTest
@testable import PeerDrop

final class SpriteRequestTests: XCTestCase {

    // MARK: - SpriteDirection: 8 PNG-named cases

    func test_spriteDirection_hasAll8Cases() {
        XCTAssertEqual(SpriteDirection.allCases.count, 8)
    }

    func test_spriteDirection_rawValues_matchPngFilenameSlugs() {
        // Slugs must match the PNG filenames inside the zip
        // (rotations/<slug>.png — see M0 spike fixture).
        XCTAssertEqual(SpriteDirection.south.rawValue,     "south")
        XCTAssertEqual(SpriteDirection.southEast.rawValue, "south-east")
        XCTAssertEqual(SpriteDirection.east.rawValue,      "east")
        XCTAssertEqual(SpriteDirection.northEast.rawValue, "north-east")
        XCTAssertEqual(SpriteDirection.north.rawValue,     "north")
        XCTAssertEqual(SpriteDirection.northWest.rawValue, "north-west")
        XCTAssertEqual(SpriteDirection.west.rawValue,      "west")
        XCTAssertEqual(SpriteDirection.southWest.rawValue, "south-west")
    }

    // MARK: - SpriteRequest: equatable + hashable

    func test_spriteRequest_equalWhenAllFieldsMatch() {
        let r1 = SpriteRequest(species: SpeciesID("cat-tabby"), stage: .adult, direction: .east)
        let r2 = SpriteRequest(species: SpeciesID("cat-tabby"), stage: .adult, direction: .east)
        XCTAssertEqual(r1, r2)
    }

    func test_spriteRequest_notEqual_whenSpeciesDiffers() {
        let r1 = SpriteRequest(species: SpeciesID("cat-tabby"), stage: .adult, direction: .east)
        let r2 = SpriteRequest(species: SpeciesID("cat-bengal"), stage: .adult, direction: .east)
        XCTAssertNotEqual(r1, r2)
    }

    func test_spriteRequest_notEqual_whenStageDiffers() {
        let r1 = SpriteRequest(species: SpeciesID("cat-tabby"), stage: .adult, direction: .east)
        let r2 = SpriteRequest(species: SpeciesID("cat-tabby"), stage: .baby, direction: .east)
        XCTAssertNotEqual(r1, r2)
    }

    func test_spriteRequest_notEqual_whenDirectionDiffers() {
        let r1 = SpriteRequest(species: SpeciesID("cat-tabby"), stage: .adult, direction: .east)
        let r2 = SpriteRequest(species: SpeciesID("cat-tabby"), stage: .adult, direction: .west)
        XCTAssertNotEqual(r1, r2)
    }

    func test_spriteRequest_usableAsDictKey() {
        var dict: [SpriteRequest: Int] = [:]
        let key = SpriteRequest(species: SpeciesID("cat-tabby"), stage: .adult, direction: .east)
        dict[key] = 42
        XCTAssertEqual(dict[key], 42)
        // Same fields → same key
        let lookup = SpriteRequest(species: SpeciesID("cat-tabby"), stage: .adult, direction: .east)
        XCTAssertEqual(dict[lookup], 42)
    }
}
