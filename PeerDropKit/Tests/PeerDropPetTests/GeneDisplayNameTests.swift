import XCTest
@testable import PeerDropPet

/// Audit round 19: the gene-info UI surfaced raw enum rawValues
/// ("cat"/"dizzy"/"stripe") which read like debug output. These tests pin
/// that every gene case has a non-empty, non-rawValue friendly displayName
/// — so a future case added to any enum fails the build's test step until
/// it gets a localized label too.
final class GeneDisplayNameTests: XCTestCase {

    func testEveryBodyGeneHasFriendlyDisplayName() {
        for gene in BodyGene.allCases {
            XCTAssertFalse(gene.displayName.isEmpty, "\(gene) has empty displayName")
            XCTAssertNotEqual(gene.displayName, gene.rawValue,
                              "\(gene).displayName still shows the raw value")
        }
    }

    func testEveryEyeGeneHasFriendlyDisplayName() {
        for gene in EyeGene.allCases {
            XCTAssertFalse(gene.displayName.isEmpty, "\(gene) has empty displayName")
            XCTAssertNotEqual(gene.displayName, gene.rawValue,
                              "\(gene).displayName still shows the raw value")
        }
    }

    func testEveryPatternGeneHasFriendlyDisplayName() {
        for gene in PatternGene.allCases {
            XCTAssertFalse(gene.displayName.isEmpty, "\(gene) has empty displayName")
            XCTAssertNotEqual(gene.displayName, gene.rawValue,
                              "\(gene).displayName still shows the raw value")
        }
    }

    func testDisplayNamesAreDistinctWithinEachEnum() {
        XCTAssertEqual(Set(BodyGene.allCases.map(\.displayName)).count, BodyGene.allCases.count)
        XCTAssertEqual(Set(EyeGene.allCases.map(\.displayName)).count, EyeGene.allCases.count)
        XCTAssertEqual(Set(PatternGene.allCases.map(\.displayName)).count, PatternGene.allCases.count)
    }
}
