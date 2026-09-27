import XCTest
@testable import peerdrop_cli
@testable import PeerDropCore
@testable import PeerDropPlatform
@testable import PeerDropProtocol
@testable import PeerDropSecurity
@testable import PeerDropTransport

/// Review item 2: ConnectionManager's FileTransferSession auto-accepts every
/// offer ("consent already given at connection level"), but in the CLI a
/// connection-level accept no longer means trusted (pending-SAS peers are
/// accepted too). The CLI therefore turns file transfer, calls and clipboard
/// sync off for the whole process.
final class CLIFeaturePolicyTests: XCTestCase {

    private var savedArgumentDomain: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        savedArgumentDomain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    }

    override func tearDown() {
        UserDefaults.standard.setVolatileDomain(savedArgumentDomain, forName: UserDefaults.argumentDomain)
        super.tearDown()
    }

    func test_apply_disablesFileTransferCallsAndClipboard_keepsChat() {
        CLIFeaturePolicy.apply(to: .standard)

        XCTAssertFalse(FeatureSettings.isFileTransferEnabled)
        XCTAssertFalse(FeatureSettings.isVoiceCallEnabled)
        XCTAssertFalse(FeatureSettings.isClipboardSyncEnabled)
        XCTAssertTrue(FeatureSettings.isChatEnabled, "chat carries the shell I/O and must stay on")
    }

    /// The override lives in the volatile argument domain, so it beats a value
    /// persisted by an earlier run (or by `defaults write`) and is never written
    /// to disk itself.
    func test_apply_overridesPersistedValue() throws {
        let suiteName = "peerdrop-cli-policy-test-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        suite.set(true, forKey: "peerDropFileTransferEnabled")

        CLIFeaturePolicy.apply(to: suite)

        XCTAssertFalse(suite.bool(forKey: "peerDropFileTransferEnabled"))
        XCTAssertEqual(suite.persistentDomain(forName: suiteName)?["peerDropFileTransferEnabled"] as? Bool, true)
    }

    /// End to end: a file offer arriving on a connection is rejected, and no
    /// FileTransferSession (which would auto-accept and write to disk) is created.
    @MainActor
    func test_fileOfferFromConnectedPeer_isNotAccepted() throws {
        CLIFeaturePolicy.apply(to: .standard)
        let cm = ConnectionManager()
        let conn = PeerConnection(
            peerID: "pending", transport: NullTransport(),
            peerIdentity: PeerIdentity(id: "pending", displayName: "lan"),
            localIdentity: PeerIdentity(id: "cli", displayName: "cli"),
            state: .connected)
        cm._setConnectionForTesting(peerID: "pending", conn)

        let offer = try PeerMessage.fileOffer(
            metadata: TransferMetadata(fileName: "big.bin", fileSize: 10_000_000_000,
                                       mimeType: nil, sha256Hash: "00"),
            senderID: "pending")
        cm.dispatchTextForTesting(offer, from: "pending")

        XCTAssertNil(conn.fileTransferSession)
    }
}
