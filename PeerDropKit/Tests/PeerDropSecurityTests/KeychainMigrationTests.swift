import XCTest
@testable import PeerDropSecurity

/// Unit-tests for the pure KeychainMigration.load orchestration.
///
/// All four tests use capture-flag closures — no real keychain calls are made.
final class KeychainMigrationTests: XCTestCase {

    // MARK: - 1. Data-protection hit → return immediately, legacy never probed

    func test_dpHit_returnsDP_neverProbesLegacy() {
        let dpData = Data([0x01, 0x02, 0x03])
        var legacyProbed = false
        var migrateCalled = false

        let result = KeychainMigration.load(
            probeDataProtection: { dpData },
            canProbeLegacy: true,           // irrelevant — should short-circuit before this matters
            probeLegacy: {
                legacyProbed = true
                return Data([0xFF])
            },
            migrate: { _ in migrateCalled = true }
        )

        XCTAssertEqual(result, dpData, "Should return the data-protection data")
        XCTAssertFalse(legacyProbed,  "Legacy keychain must NOT be probed when DP hit")
        XCTAssertFalse(migrateCalled, "migrate must NOT be called when DP hit")
    }

    // MARK: - 2. DP miss + canProbeLegacy=false → nil, legacy never probed

    func test_dpMiss_cannotProbeLegacy_returnsNil() {
        var legacyProbed = false
        var migrateCalled = false

        let result = KeychainMigration.load(
            probeDataProtection: { nil },
            canProbeLegacy: false,
            probeLegacy: {
                legacyProbed = true
                return Data([0xAB])
            },
            migrate: { _ in migrateCalled = true }
        )

        XCTAssertNil(result,           "Should return nil when canProbeLegacy is false")
        XCTAssertFalse(legacyProbed,   "Legacy keychain must NOT be probed for CLI/xctest")
        XCTAssertFalse(migrateCalled,  "migrate must NOT be called")
    }

    // MARK: - 3. DP miss + canProbeLegacy=true + legacy miss → nil, migrate never called

    func test_dpMiss_legacyMiss_returnsNil() {
        var migrateCalled = false

        let result = KeychainMigration.load(
            probeDataProtection: { nil },
            canProbeLegacy: true,
            probeLegacy: { nil },
            migrate: { _ in migrateCalled = true }
        )

        XCTAssertNil(result,          "Should return nil when both keychains miss")
        XCTAssertFalse(migrateCalled, "migrate must NOT be called when legacy also misses")
    }

    // MARK: - 4. DP miss + canProbeLegacy=true + legacy hit → return legacy data AND migrate called once

    func test_dpMiss_legacyHit_returnsMigratedData_migrateCalledOnce() {
        let legacyData = Data([0xDE, 0xAD, 0xBE, 0xEF])
        var migrateCallCount = 0
        var migratedPayload: Data?

        let result = KeychainMigration.load(
            probeDataProtection: { nil },
            canProbeLegacy: true,
            probeLegacy: { legacyData },
            migrate: { data in
                migrateCallCount += 1
                migratedPayload = data
            }
        )

        XCTAssertEqual(result, legacyData,
                       "Should return the legacy data so the caller can proceed")
        XCTAssertEqual(migrateCallCount, 1,
                       "migrate must be called exactly once")
        XCTAssertEqual(migratedPayload, legacyData,
                       "migrate must receive the exact legacy data payload")
    }
}
