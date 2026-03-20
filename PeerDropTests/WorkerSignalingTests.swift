import XCTest
@testable import PeerDrop

final class WorkerSignalingTests: XCTestCase {

    func testDefaultWorkerURL() {
        // The default worker URL should be a valid HTTPS URL
        let url = WorkerSignaling.workerURL
        XCTAssertTrue(url.hasPrefix("https://"), "Worker URL should use HTTPS")
        XCTAssertNotNil(URL(string: url), "Worker URL should be valid")
    }

    func testWorkerSignalingInit() {
        let signaling = WorkerSignaling()
        // Should initialize without crashing
        XCTAssertNotNil(signaling)
    }

    func testWorkerSignalingCustomURL() {
        let customURL = URL(string: "https://custom.example.com")!
        let signaling = WorkerSignaling(baseURL: customURL)
        XCTAssertNotNil(signaling)
    }

    func testWorkerSignalingErrorDescriptions() {
        XCTAssertNotNil(WorkerSignalingError.roomCreationFailed.errorDescription)
        XCTAssertNotNil(WorkerSignalingError.roomNotFound.errorDescription)
        XCTAssertNotNil(WorkerSignalingError.iceCredentialsFailed.errorDescription)
        XCTAssertNotNil(WorkerSignalingError.noTURNCredentials.errorDescription)
        XCTAssertNotNil(WorkerSignalingError.webSocketError.errorDescription)
    }
}
