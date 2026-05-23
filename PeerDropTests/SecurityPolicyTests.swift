import XCTest
@testable import PeerDrop

final class SecurityPolicyTests: XCTestCase {
    func test_OPKExhaustionBehavior_strictness_ordering() {
        XCTAssertGreaterThan(
            SecurityPolicy.OPKExhaustionBehavior.failClosed,
            SecurityPolicy.OPKExhaustionBehavior.proceedWithoutDH4,
            "failClosed is strictly stronger than proceedWithoutDH4"
        )
    }

    func test_SPKExpirationBehavior_strictness_ordering() {
        XCTAssertGreaterThan(
            SecurityPolicy.SPKExpirationBehavior.reject,
            SecurityPolicy.SPKExpirationBehavior.warn,
            "reject is strictly stronger than warn"
        )
    }

    func test_bundledDefault_matchesSpec() {
        let p = SecurityPolicy.bundledDefault
        XCTAssertEqual(p.spkMaxAgeDays, 21)
        XCTAssertEqual(p.spkExpirationBehavior, .warn)
        XCTAssertEqual(p.opkExhaustionBehavior(.legacy), .proceedWithoutDH4)
        XCTAssertEqual(p.opkExhaustionBehavior(.v5_4_plus), .failClosed)
        XCTAssertEqual(p.opkExhaustionBehavior(.unknown), .failClosed)
        XCTAssertEqual(p.opkRetryMaxAttempts, 5)
        XCTAssertEqual(p.opkRetryIntervalSeconds, 60)
        XCTAssertEqual(p.skippedKeyTTLDays, 30)
        XCTAssertEqual(p.skippedKeyMaxCount, 200)
        XCTAssertEqual(p.consumedOPKPruneWindowDays, 90)
    }

    func test_bounds_clamp_outOfRangeValues() {
        let raw = SecurityPolicy(
            spkMaxAgeDays: 0,        // below min (7)
            spkExpirationBehavior: .warn,
            opkExhaustionLegacy: .proceedWithoutDH4,
            opkExhaustionStrict: .failClosed,
            opkRetryMaxAttempts: 999, // above max (20)
            opkRetryIntervalSeconds: 5, // below min (30)
            skippedKeyTTLDays: 30,
            skippedKeyMaxCount: 200,
            consumedOPKPruneWindowDays: 90
        )
        let clamped = SecurityPolicyBounds.clamp(raw)
        XCTAssertEqual(clamped.spkMaxAgeDays, 7)
        XCTAssertEqual(clamped.opkRetryMaxAttempts, 20)
        XCTAssertEqual(clamped.opkRetryIntervalSeconds, 30)
        // Bonus: confirm in-range fields pass through unchanged.
        XCTAssertEqual(clamped.skippedKeyMaxCount, 200)
    }

    func test_bounds_violations_listsOutOfRangeFields() {
        let raw = SecurityPolicy(
            spkMaxAgeDays: 0,        // below min
            spkExpirationBehavior: .warn,
            opkExhaustionLegacy: .proceedWithoutDH4,
            opkExhaustionStrict: .failClosed,
            opkRetryMaxAttempts: 5,
            opkRetryIntervalSeconds: 60,
            skippedKeyTTLDays: 30,
            skippedKeyMaxCount: 200,
            consumedOPKPruneWindowDays: 90
        )
        let violations = SecurityPolicyBounds.violations(raw)
        XCTAssertEqual(violations, ["spkMaxAgeDays"])

        let allInRange = SecurityPolicy.bundledDefault
        XCTAssertEqual(SecurityPolicyBounds.violations(allInRange), [])
    }

    func test_merge_strongerOfTwo_spkMaxAge() {
        let local = SecurityPolicy.bundledDefault  // spkMaxAge = 21
        let remote = SecurityPolicy(
            spkMaxAgeDays: 14,  // stricter
            spkExpirationBehavior: .warn,
            opkExhaustionLegacy: .proceedWithoutDH4,
            opkExhaustionStrict: .failClosed,
            opkRetryMaxAttempts: 5,
            opkRetryIntervalSeconds: 60,
            skippedKeyTTLDays: 30,
            skippedKeyMaxCount: 200,
            consumedOPKPruneWindowDays: 90
        )
        let merged = SecurityPolicy.merged(local: local, remote: remote)
        XCTAssertEqual(merged.spkMaxAgeDays, 14, "merge picks the shorter (stricter)")
    }

    func test_merge_strongerOfTwo_neverWeakerThanInput() {
        let a = SecurityPolicy.bundledDefault
        let b = SecurityPolicy(
            spkMaxAgeDays: 60,
            spkExpirationBehavior: .reject,  // stricter on this field
            opkExhaustionLegacy: .proceedWithoutDH4,
            opkExhaustionStrict: .failClosed,
            opkRetryMaxAttempts: 10,
            opkRetryIntervalSeconds: 60,
            skippedKeyTTLDays: 60,
            skippedKeyMaxCount: 100,  // stricter (smaller)
            consumedOPKPruneWindowDays: 180  // stricter (larger)
        )
        let m = SecurityPolicy.merged(local: a, remote: b)
        XCTAssertLessThanOrEqual(m.spkMaxAgeDays, min(a.spkMaxAgeDays, b.spkMaxAgeDays))
        XCTAssertGreaterThanOrEqual(m.spkExpirationBehavior, max(a.spkExpirationBehavior, b.spkExpirationBehavior))
        XCTAssertLessThanOrEqual(m.skippedKeyMaxCount, min(a.skippedKeyMaxCount, b.skippedKeyMaxCount))
        XCTAssertGreaterThanOrEqual(m.consumedOPKPruneWindowDays, max(a.consumedOPKPruneWindowDays, b.consumedOPKPruneWindowDays))
    }

    func test_invariant_pruneWindow_geq_spkMaxAge_times_4() {
        XCTAssertNoThrow(try SecurityPolicy.bundledDefault.validateInvariants())

        let bad = SecurityPolicy(
            spkMaxAgeDays: 30,
            spkExpirationBehavior: .warn,
            opkExhaustionLegacy: .proceedWithoutDH4,
            opkExhaustionStrict: .failClosed,
            opkRetryMaxAttempts: 5,
            opkRetryIntervalSeconds: 60,
            skippedKeyTTLDays: 30,
            skippedKeyMaxCount: 200,
            consumedOPKPruneWindowDays: 90  // 90 < 30*4=120 → violation
        )
        XCTAssertThrowsError(try bad.validateInvariants()) { error in
            guard case SecurityPolicy.InvariantError.pruneWindowTooShort = error else {
                return XCTFail("expected pruneWindowTooShort, got \(error)")
            }
        }
    }

    func test_merge_opkRetryIntervalSeconds_localWins() {
        let local = SecurityPolicy(
            spkMaxAgeDays: 21,
            spkExpirationBehavior: .warn,
            opkExhaustionLegacy: .proceedWithoutDH4,
            opkExhaustionStrict: .failClosed,
            opkRetryMaxAttempts: 5,
            opkRetryIntervalSeconds: 45,   // local pick
            skippedKeyTTLDays: 30,
            skippedKeyMaxCount: 200,
            consumedOPKPruneWindowDays: 90
        )
        let remote = SecurityPolicy(
            spkMaxAgeDays: 21,
            spkExpirationBehavior: .warn,
            opkExhaustionLegacy: .proceedWithoutDH4,
            opkExhaustionStrict: .failClosed,
            opkRetryMaxAttempts: 5,
            opkRetryIntervalSeconds: 600,  // remote tries to override
            skippedKeyTTLDays: 30,
            skippedKeyMaxCount: 200,
            consumedOPKPruneWindowDays: 90
        )
        let merged = SecurityPolicy.merged(local: local, remote: remote)
        XCTAssertEqual(merged.opkRetryIntervalSeconds, 45,
                       "opkRetryIntervalSeconds is pure UX — local wins regardless of remote")
    }

    // MARK: - Codable wire shape (spec §5.1)

    func test_codable_encodes_nested_opkExhaustionBehavior() throws {
        let data = try JSONEncoder().encode(SecurityPolicy.bundledDefault)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        // Top-level scalars present
        XCTAssertEqual(json["spkMaxAgeDays"] as? Int, 21)
        XCTAssertEqual(json["spkExpirationBehavior"] as? String, "warn")
        XCTAssertEqual(json["opkRetryMaxAttempts"] as? Int, 5)
        XCTAssertEqual(json["opkRetryIntervalSeconds"] as? Int, 60)
        XCTAssertEqual(json["skippedKeyTTLDays"] as? Int, 30)
        XCTAssertEqual(json["skippedKeyMaxCount"] as? Int, 200)
        XCTAssertEqual(json["consumedOPKPruneWindowDays"] as? Int, 90)

        // Nested opkExhaustionBehavior (spec §5.1)
        let opk = json["opkExhaustionBehavior"] as? [String: String]
        XCTAssertNotNil(opk, "opkExhaustionBehavior must encode as a nested object")
        XCTAssertEqual(opk?["legacy"], "proceedWithoutDH4")
        XCTAssertEqual(opk?["strict"], "failClosed")

        // No leaked flat keys from the previous synthesized encoding
        XCTAssertNil(json["opkExhaustionLegacy"], "flat shape leaked — must be nested")
        XCTAssertNil(json["opkExhaustionStrict"], "flat shape leaked — must be nested")
    }

    func test_codable_roundTrip_preservesAllFields() throws {
        let original = SecurityPolicy(
            spkMaxAgeDays: 14,
            spkExpirationBehavior: .reject,
            opkExhaustionLegacy: .failClosed,
            opkExhaustionStrict: .failClosed,
            opkRetryMaxAttempts: 10,
            opkRetryIntervalSeconds: 120,
            skippedKeyTTLDays: 60,
            skippedKeyMaxCount: 500,
            consumedOPKPruneWindowDays: 365
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SecurityPolicy.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func test_codable_decodes_specShape() throws {
        // Hand-written JSON in the exact shape spec §5.1 documents.
        let json = """
        {
          "spkMaxAgeDays": 21,
          "spkExpirationBehavior": "warn",
          "opkExhaustionBehavior": {
            "legacy": "proceedWithoutDH4",
            "strict": "failClosed"
          },
          "opkRetryMaxAttempts": 5,
          "opkRetryIntervalSeconds": 60,
          "skippedKeyTTLDays": 30,
          "skippedKeyMaxCount": 200,
          "consumedOPKPruneWindowDays": 90
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SecurityPolicy.self, from: json)
        XCTAssertEqual(decoded, .bundledDefault)
    }
}
