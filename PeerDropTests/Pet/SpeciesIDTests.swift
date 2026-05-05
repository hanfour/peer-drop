import XCTest
@testable import PeerDrop

private struct SpeciesIDHolder: Codable, Equatable {
    let id: SpeciesID
}

final class SpeciesIDTests: XCTestCase {

    // MARK: - family / variant parsing

    func test_family_returnsPrefixBeforeFirstHyphen() {
        XCTAssertEqual(SpeciesID("cat-tabby").family, "cat")
        XCTAssertEqual(SpeciesID("redpanda-snow").family, "redpanda")
        XCTAssertEqual(SpeciesID("bear-panda").family, "bear")
    }

    func test_variant_returnsRemainderAfterFirstHyphen() {
        XCTAssertEqual(SpeciesID("cat-tabby").variant, "tabby")
        XCTAssertEqual(SpeciesID("redpanda-snow").variant, "snow")
        XCTAssertEqual(SpeciesID("bear-panda").variant, "panda")
    }

    func test_familyOnlyID_hasNilVariant() {
        XCTAssertEqual(SpeciesID("octopus").family, "octopus")
        XCTAssertNil(SpeciesID("octopus").variant)
    }

    // MARK: - rawValue / equality

    func test_rawValue_roundTrips() {
        XCTAssertEqual(SpeciesID("cat-tabby").rawValue, "cat-tabby")
    }

    func test_equatable_byRawValue() {
        XCTAssertEqual(SpeciesID("cat-tabby"), SpeciesID("cat-tabby"))
        XCTAssertNotEqual(SpeciesID("cat-tabby"), SpeciesID("cat-bengal"))
    }

    // MARK: - Codable as plain string (single-value container)

    func test_codable_encodesAsPlainString() throws {
        let holder = SpeciesIDHolder(id: SpeciesID("cat-tabby"))
        let data = try JSONEncoder().encode(holder)
        XCTAssertEqual(String(data: data, encoding: .utf8), #"{"id":"cat-tabby"}"#)
    }

    func test_codable_decodesFromPlainString() throws {
        let json = #"{"id":"slime-fire"}"#.data(using: .utf8)!
        let holder = try JSONDecoder().decode(SpeciesIDHolder.self, from: json)
        XCTAssertEqual(holder.id, SpeciesID("slime-fire"))
    }

    func test_codable_roundTripPreservesRawValue() throws {
        let original = SpeciesIDHolder(id: SpeciesID("phoenix-light"))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SpeciesIDHolder.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Hashable (used as cache key in M3)

    func test_hashable_canBeUsedAsDictKey() {
        var dict: [SpeciesID: Int] = [:]
        dict[SpeciesID("cat-tabby")] = 1
        dict[SpeciesID("cat-bengal")] = 2
        XCTAssertEqual(dict[SpeciesID("cat-tabby")], 1)
        XCTAssertEqual(dict[SpeciesID("cat-bengal")], 2)
    }

    // MARK: - Edge cases (locked behavior, not validation contracts)

    // SpeciesID does not validate its input — these tests pin current behavior so
    // future "let's add validation" changes are intentional and visible in the diff.

    func test_emptyString_returnsEmptyFamily_andNilVariant() {
        let id = SpeciesID("")
        XCTAssertEqual(id.family, "")
        XCTAssertNil(id.variant)
    }

    func test_trailingHyphen_returnsEmptyVariantString_notNil() {
        // "cat-" has a hyphen → variant is the (empty) suffix, not nil.
        let id = SpeciesID("cat-")
        XCTAssertEqual(id.family, "cat")
        XCTAssertEqual(id.variant, "")
    }

    func test_multipleHyphens_splitOnFirstHyphenOnly() {
        // Family token convention forbids internal hyphens, but the parser is
        // tolerant: everything after the first hyphen is the variant.
        let id = SpeciesID("a-b-c")
        XCTAssertEqual(id.family, "a")
        XCTAssertEqual(id.variant, "b-c")
    }
}
