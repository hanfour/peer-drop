import XCTest
@testable import PeerDrop

/// Tests for the file-coordinated SharedPetState. Covers the basic
/// write/read round-trip plus the partial-write race that the previous
/// UserDefaults-based implementation could not avoid.
final class SharedPetStateTests: XCTestCase {

    private func makeSnapshot(experience: Int = 42, name: String = "Pixel") -> PetSnapshot {
        PetSnapshot(
            name: name, bodyType: .cat, eyeType: .dot, patternType: .none,
            level: .baby, mood: .happy, paletteIndex: 0,
            experience: experience, maxExperience: 500)
    }

    override func setUp() {
        super.setUp()
        // Hermetic: the suiteName=nil branch falls through to a per-process
        // temp dir, so each test case runs against a clean container.
        SharedPetState(suiteName: nil).clear()
    }

    override func tearDown() {
        SharedPetState(suiteName: nil).clear()
        super.tearDown()
    }

    func testWriteAndReadPetSnapshot() {
        let shared = SharedPetState(suiteName: nil)
        let snapshot = makeSnapshot()
        shared.write(snapshot)
        let read = shared.read()
        XCTAssertNotNil(read)
        XCTAssertEqual(read?.name, "Pixel")
        XCTAssertEqual(read?.bodyType, .cat)
        XCTAssertEqual(read?.level, .baby)
        XCTAssertEqual(read?.experience, 42)
    }

    func testWriteReadRoundTripExactEquality() {
        let shared = SharedPetState(suiteName: nil)
        let snapshot = makeSnapshot()
        shared.write(snapshot)
        XCTAssertEqual(shared.read(), snapshot)
    }

    func testReadReturnsNilWhenEmpty() {
        let shared = SharedPetState(suiteName: nil)
        shared.clear()
        XCTAssertNil(shared.read())
    }

    func testClearRemovesFile() {
        let shared = SharedPetState(suiteName: nil)
        shared.write(makeSnapshot())
        XCTAssertNotNil(shared.read())
        shared.clear()
        XCTAssertNil(shared.read())
    }

    func testClearIsIdempotent() {
        let shared = SharedPetState(suiteName: nil)
        shared.clear()
        shared.clear() // no file present — must not crash
        XCTAssertNil(shared.read())
    }

    func testLastWriteWinsAndIsValid() {
        let shared = SharedPetState(suiteName: nil)
        for i in 0..<10 {
            shared.write(makeSnapshot(experience: i))
        }
        let read = shared.read()
        XCTAssertNotNil(read)
        XCTAssertEqual(read?.experience, 9)
    }

    /// NSFileCoordinator + atomic writes serialize concurrent writers, so the
    /// final read must return ONE valid snapshot (never partial JSON / nil).
    func testConcurrentWritesProduceValidFinalSnapshot() {
        let shared = SharedPetState(suiteName: nil)
        let writeCount = 20
        let group = DispatchGroup()
        for i in 0..<writeCount {
            group.enter()
            DispatchQueue.global().async {
                shared.write(self.makeSnapshot(experience: i))
                group.leave()
            }
        }
        group.wait()

        let final = shared.read()
        XCTAssertNotNil(final, "Final read after concurrent writes must succeed")
        // The winner is non-deterministic but must be one of the values written.
        let validRange = 0..<writeCount
        XCTAssertTrue(validRange.contains(final?.experience ?? -1),
                      "experience=\(String(describing: final?.experience)) must be in 0..<\(writeCount)")
    }

    /// On first launch of v3.4, existing v3.3.x users have a snapshot stored
    /// in UserDefaults under "petSnapshot". SharedPetState's init must
    /// migrate that blob into the file and clear the legacy key.
    func testMigratesLegacyUserDefaultsBlob() throws {
        let suiteName = "test.peerdrop.migration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let legacy = makeSnapshot(experience: 123, name: "Legacy")
        let legacyData = try JSONEncoder().encode(legacy)
        defaults.set(legacyData, forKey: "petSnapshot")
        XCTAssertNotNil(defaults.data(forKey: "petSnapshot"))

        // Note: this branch will hit the "no app group container" path and
        // fall through to the temp dir, but the legacy migration uses the
        // same suiteName for UserDefaults, so we can verify the key is wiped.
        // We do not assert read() here because the temp-dir container is
        // shared across this test class; the migration's correctness is
        // demonstrated by the legacy key being removed after init.
        _ = SharedPetState(suiteName: suiteName)
        XCTAssertNil(defaults.data(forKey: "petSnapshot"),
                     "Legacy UserDefaults entry must be removed after migration")
    }

    func testMigrationSkipsCorruptedLegacyBlob() throws {
        let suiteName = "test.peerdrop.migration.corrupt.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        // Garbage bytes that do not decode to PetSnapshot.
        defaults.set(Data([0xDE, 0xAD, 0xBE, 0xEF]), forKey: "petSnapshot")

        _ = SharedPetState(suiteName: suiteName)
        XCTAssertNil(defaults.data(forKey: "petSnapshot"),
                     "Corrupt legacy blob must be discarded, not migrated")
    }

    /// Concurrent readers must never observe a corrupted snapshot, even
    /// while writers are in flight.
    func testConcurrentReadsDuringWritesAreNeverCorrupt() {
        let shared = SharedPetState(suiteName: nil)
        // Seed with a known-good snapshot first.
        shared.write(makeSnapshot(experience: 0))

        let group = DispatchGroup()
        let writerCount = 10
        let readerCount = 50

        for i in 0..<writerCount {
            group.enter()
            DispatchQueue.global().async {
                shared.write(self.makeSnapshot(experience: i))
                group.leave()
            }
        }
        for _ in 0..<readerCount {
            group.enter()
            DispatchQueue.global().async {
                let snap = shared.read()
                // Must be either nil (briefly during clear/delete) OR a valid
                // decoded PetSnapshot — never partial garbage.
                if let snap = snap {
                    XCTAssertEqual(snap.bodyType, .cat)
                    XCTAssertEqual(snap.level, .baby)
                }
                group.leave()
            }
        }
        group.wait()
    }
}
