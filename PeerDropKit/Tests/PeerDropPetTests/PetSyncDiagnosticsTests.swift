import XCTest
@testable import PeerDropPet

/// The diagnostic renders the invisible iCloud-sync state into a readable
/// verdict so the 2-device verification (roadmap §3) isn't guesswork.
final class PetSyncDiagnosticsTests: XCTestCase {

    private func snap(
        account: Bool = true,
        container: String? = "file:///…/iCloud~com~hanfour~peerdrop",
        localID: String? = "PET-A", localAt: Date? = Date(timeIntervalSince1970: 1000),
        cloudID: String? = "PET-A", cloudAt: Date? = Date(timeIntervalSince1970: 1000),
        kvsID: String? = "PET-A", level: Int? = 2, exp: Int? = 40
    ) -> PetSyncDiagnostics.Snapshot {
        PetSyncDiagnostics.Snapshot(
            capturedAt: Date(timeIntervalSince1970: 2000),
            iCloudAccountAvailable: account, ubiquityContainerURL: container,
            localPetID: localID, localUpdatedAt: localAt,
            cloudPetID: cloudID, cloudUpdatedAt: cloudAt,
            kvsPetID: kvsID, kvsLevel: level, kvsExperience: exp)
    }

    func test_verdict_iCloudUnavailable() {
        let out = PetSyncDiagnostics.render(snap(account: false, container: nil))
        XCTAssertTrue(out.contains("iCLOUD UNAVAILABLE"), out)
    }

    func test_verdict_inSync() {
        let out = PetSyncDiagnostics.render(snap())
        XCTAssertTrue(out.contains("IN SYNC"), out)
    }

    func test_verdict_cloudAhead() {
        // Same pet, cloud written later → this device should pull.
        let out = PetSyncDiagnostics.render(snap(localAt: Date(timeIntervalSince1970: 1000),
                                                 cloudAt: Date(timeIntervalSince1970: 1500)))
        XCTAssertTrue(out.contains("CLOUD AHEAD"), out)
    }

    func test_verdict_localOnly() {
        let out = PetSyncDiagnostics.render(snap(cloudID: nil, cloudAt: nil))
        XCTAssertTrue(out.contains("LOCAL ONLY"), out)
    }

    func test_render_includesKvsHeartbeat() {
        let out = PetSyncDiagnostics.render(snap(level: 3, exp: 120))
        XCTAssertTrue(out.contains("level 3"), out)
        XCTAssertTrue(out.contains("120"), out)
    }
}
