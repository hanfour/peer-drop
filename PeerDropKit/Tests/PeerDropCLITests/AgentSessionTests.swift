import XCTest
@testable import peerdrop_cli
@testable import PeerDropSecurity

// MARK: - Test-only TrustedContactStore helper

extension TrustedContactStore {
    /// Creates a store backed by a unique temporary directory so tests never
    /// share state and never touch the keychain (no existing file → load returns []).
    static func inMemory() -> TrustedContactStore {
        // Use a UUID-named key so the storage file path is unique per call.
        // No file will exist at that path, so load() returns [] immediately
        // without touching ChatDataEncryptor / the keychain.
        let key = "test-\(UUID().uuidString)"
        return TrustedContactStore(storageKey: key)
    }
}

// MARK: - AgentSessionTests

final class AgentSessionTests: XCTestCase {

    func test_trustedKeyIsAutoAccepted() {
        let store = TrustedContactStore.inMemory()
        let key = Data((0..<32).map { UInt8($0) })
        store.add(TrustedContact(displayName: "iPhone",
                                 identityPublicKey: key,
                                 trustLevel: .verified))
        let decision = AgentSession.decideTrust(identityKey: key, store: store)
        XCTAssertEqual(decision, .autoAccept)
    }

    func test_unknownKeyRequiresEnrollment() {
        let store = TrustedContactStore.inMemory()
        let key = Data((0..<32).map { UInt8($0) })
        let decision = AgentSession.decideTrust(identityKey: key, store: store)
        XCTAssertEqual(decision, .enroll)
    }

    func test_blockedKeyIsRejected() {
        let store = TrustedContactStore.inMemory()
        let key = Data((0..<32).map { UInt8($0) })
        var c = TrustedContact(displayName: "bad",
                               identityPublicKey: key,
                               trustLevel: .verified)
        c.isBlocked = true
        store.add(c)
        XCTAssertEqual(AgentSession.decideTrust(identityKey: key, store: store), .reject)
    }

    /// A contact that is in the store, not blocked, but has `trustLevel == .unknown`
    /// must return `.enroll` — they have not yet been paired or verified.
    func test_unknownTrustLevelContactRequiresEnrollment() {
        let store = TrustedContactStore.inMemory()
        let key = Data((0..<32).map { UInt8($0) })
        store.add(TrustedContact(displayName: "pending",
                                 identityPublicKey: key,
                                 trustLevel: .unknown))
        XCTAssertEqual(AgentSession.decideTrust(identityKey: key, store: store), .enroll)
    }
}
