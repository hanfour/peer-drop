import XCTest
@testable import PeerDrop

final class CanonicalJSONTests: XCTestCase {

    func test_canonicalize_sortsTopLevelKeys() throws {
        let json: [String: Any] = ["b": 2, "a": 1, "c": 3]
        let data = try CanonicalJSON.serialize(json)
        XCTAssertEqual(
            String(data: data, encoding: .utf8),
            #"{"a":1,"b":2,"c":3}"#
        )
    }

    func test_canonicalize_sortsNestedKeys() throws {
        let json: [String: Any] = [
            "outer": ["z": 1, "a": 2],
            "alpha": 9
        ]
        let data = try CanonicalJSON.serialize(json)
        // Both top-level and nested keys must be sorted.
        XCTAssertEqual(
            String(data: data, encoding: .utf8),
            #"{"alpha":9,"outer":{"a":2,"z":1}}"#
        )
    }

    func test_canonicalize_preservesArrayOrder() throws {
        // Arrays are positional, NOT sorted — order is significant.
        let json: [String: Any] = ["arr": [3, 1, 2]]
        let data = try CanonicalJSON.serialize(json)
        XCTAssertEqual(
            String(data: data, encoding: .utf8),
            #"{"arr":[3,1,2]}"#
        )
    }

    func test_canonicalize_isDeterministic_acrossRuns() throws {
        let json: [String: Any] = [
            "schemaVersion": 1,
            "issuedAt": 1_748_000_000,
            "expiresAt": 1_750_592_000,
            "policy": [
                "spkMaxAgeDays": 21,
                "skippedKeyMaxCount": 200,
                "consumedOPKPruneWindowDays": 90,
            ]
        ]
        let a = try CanonicalJSON.serialize(json)
        let b = try CanonicalJSON.serialize(json)
        XCTAssertEqual(a, b)
    }

    func test_canonicalize_rejects_unsupportedType() {
        // Date is not in the supported set — canonicalization is for
        // primitives + containers only. Caller must serialize Date to
        // its preferred string form first.
        let json: [String: Any] = ["d": Date()]
        XCTAssertThrowsError(try CanonicalJSON.serialize(json))
    }
}
