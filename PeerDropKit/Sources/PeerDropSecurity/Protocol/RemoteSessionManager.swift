import Foundation
import CryptoKit
import os.log

/// Manages encrypted remote sessions with peers via X3DH + Double Ratchet.
/// Coordinates with MailboxClient for message delivery and PreKeyStore for key material.
@MainActor
public final class RemoteSessionManager: ObservableObject {

    private static let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "RemoteSessionManager")

    private var sessions: [String: DoubleRatchetSession] = [:] // keyed by contact UUID
    private let preKeyStore: PreKeyStore
    private let mailboxClient: any MailboxServiceProtocol

    /// Injected by ConnectionManager (or directly in tests). When non-nil, each
    /// `decrypt` call runs the TTL + LRU eviction passes with these settings.
    public var policyStore: SecurityPolicyStore?

    /// Injected alongside `policyStore`. Records C3 eviction + hit events.
    public var cryptoMetrics: CryptoHardeningMetrics?

    public init(preKeyStore: PreKeyStore = PreKeyStore(), mailboxClient: any MailboxServiceProtocol) {
        self.preKeyStore = preKeyStore
        self.mailboxClient = mailboxClient
        loadAllSessions()
    }

    /// Result of initiating an X3DH session, including metadata needed for the initial message envelope.
    public struct InitiateResult {
        public let session: DoubleRatchetSession
        public let ephemeralPublicKey: Data        // Sender's ephemeral key (for receiver to complete X3DH)
        public let usedSignedPreKeyId: UInt32      // Which signed pre-key was used
        public let usedOneTimePreKeyId: UInt32?    // Which OTP key was consumed (if any)
    }

    // MARK: - Initiate Session (Alice side)

    public func initiateSession(
        contactId: String,
        peerMailboxId: String
    ) async throws -> InitiateResult {
        let bundle = try await mailboxClient.fetchSecurityPreKeyBundle(mailboxId: peerMailboxId)

        // Validate signed pre-key signature (legacy — pre-C1, over SPK_pubkey alone).
        let signingPub = try Curve25519.Signing.PublicKey(rawRepresentation: bundle.signingKey)
        guard bundle.signedPreKey.verify(with: signingPub) else {
            throw RemoteSessionError.invalidSignedPreKey
        }

        // C1 freshness gate (PR6 / spec §4.1). 5-branch matrix:
        //   - legacy peer (both nil) → returns .legacy
        //   - v5.4+ fresh / .warn-mode expired → returns .v5_4_plus
        //   - malformed / invalid sig / .reject-mode expired → throws, propagates out
        // peerVersion is passed to initiatorKeyAgreement below so the C2 OPK gate
        // (PR5) routes correctly: legacy peer → proceedWithoutDH4, v5.4+ → failClosed.
        let peerVersion = try X3DH.verifyBundleFreshness(
            signedPreKeyPublicKey: bundle.signedPreKey.publicKey,
            signedPreKeyTimestamp: bundle.signedPreKeyTimestamp,
            signedPreKeyTimestampSignature: bundle.signedPreKeyTimestampSignature,
            peerSigningKey: signingPub,
            now: Date(),
            policy: policyStore?.current ?? .bundledDefault,
            metrics: cryptoMetrics
        )

        let theirIdentityKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: bundle.identityKey)
        let theirSignedPreKey = try bundle.signedPreKey.agreementPublicKey()

        var theirOneTimePreKey: Curve25519.KeyAgreement.PublicKey?
        if let otpk = bundle.oneTimePreKeys.first {
            theirOneTimePreKey = try otpk.agreementPublicKey()
        }

        let ephemeralKey = Curve25519.KeyAgreement.PrivateKey()
        let x3dhResult = try X3DH.initiatorKeyAgreement(
            myIdentityKey: IdentityKeyManager.shared.agreementPrivateKeyForX3DH(),
            myEphemeralKey: ephemeralKey,
            theirIdentityKey: theirIdentityKey,
            theirSignedPreKey: theirSignedPreKey,
            theirOneTimePreKey: theirOneTimePreKey,
            peerVersion: peerVersion,
            policy: policyStore?.current ?? .bundledDefault,
            metrics: cryptoMetrics
        )

        let session = DoubleRatchetSession.initializeAsInitiator(
            rootKey: x3dhResult.rootKey,
            theirRatchetKey: theirSignedPreKey
        )

        sessions[contactId] = session
        saveSession(for: contactId)
        Self.logger.info("Remote session initiated with contact \(contactId)")
        return InitiateResult(
            session: session,
            ephemeralPublicKey: ephemeralKey.publicKey.rawRepresentation,
            usedSignedPreKeyId: bundle.signedPreKey.id,
            usedOneTimePreKeyId: bundle.oneTimePreKeys.first?.id
        )
    }

    // MARK: - Respond to Session (Bob side)

    /// **SECURITY**: Callers MUST verify peer trust before invoking this method.
    /// This function performs no consent gating — it unconditionally derives
    /// shared keys and persists a session. The first-contact verification gate
    /// lives in `ConnectionManager.handleRemoteMessage`; any new caller of this
    /// method must implement equivalent gating or the X3DH-MITM property is lost.
    public func respondToSession(
        contactId: String,
        theirIdentityKey: Data,
        theirEphemeralKey: Data,
        usedSignedPreKeyId: UInt32,
        usedOneTimePreKeyId: UInt32?
    ) throws -> DoubleRatchetSession {
        let theirIdKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirIdentityKey)
        let theirEphKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirEphemeralKey)

        guard let signedPreKey = try preKeyStore.signedPreKey(for: usedSignedPreKeyId) else {
            throw RemoteSessionError.unknownSignedPreKey
        }

        var oneTimePreKey: Curve25519.KeyAgreement.PrivateKey?
        if let otpkId = usedOneTimePreKeyId,
           let otpk = try preKeyStore.consumeOneTimePreKey(id: otpkId) {
            oneTimePreKey = try otpk.agreementPrivateKey()
        }

        let mySignedPreKeyPrivate = try signedPreKey.agreementPrivateKey()

        let x3dhResult = try X3DH.responderKeyAgreement(
            myIdentityKey: IdentityKeyManager.shared.agreementPrivateKeyForX3DH(),
            mySignedPreKey: mySignedPreKeyPrivate,
            myOneTimePreKey: oneTimePreKey,
            theirIdentityKey: theirIdKey,
            theirEphemeralKey: theirEphKey
        )

        let session = DoubleRatchetSession.initializeAsResponder(
            rootKey: x3dhResult.rootKey,
            myRatchetKey: mySignedPreKeyPrivate
        )

        sessions[contactId] = session
        saveSession(for: contactId)
        Self.logger.info("Remote session established as responder for contact \(contactId)")
        return session
    }

    // MARK: - Encrypt / Decrypt

    public func encrypt(data: Data, for contactId: String) throws -> RatchetMessage {
        guard let session = sessions[contactId] else {
            throw RemoteSessionError.noSession
        }
        let result = try session.encrypt(data)
        saveSession(for: contactId)
        return result
    }

    public func decrypt(message: RatchetMessage, from contactId: String) throws -> Data {
        guard let session = sessions[contactId] else {
            throw RemoteSessionError.noSession
        }
        let result = try session.decrypt(message, policy: policyStore?.current, metrics: cryptoMetrics)
        saveSession(for: contactId)
        return result
    }

    public func hasSession(for contactId: String) -> Bool {
        sessions[contactId] != nil
    }

    // MARK: - Session Persistence

    private static var sessionsDirectory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Security", isDirectory: true)
        let dir: URL
        if let ns = PeerDropPersistence.fileStore?.namespace {
            dir = base.appendingPathComponent("sessions-\(ns)", isDirectory: true)
        } else {
            dir = base.appendingPathComponent("sessions", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private let encryptor = ChatDataEncryptor.shared

    public func saveSession(for contactId: String) {
        guard let session = sessions[contactId] else { return }
        do {
            let data = try JSONEncoder().encode(session)
            let url = Self.sessionsDirectory.appendingPathComponent("\(contactId).enc")
            try encryptor.encryptAndWrite(data, to: url)
        } catch {
            Self.logger.error("Failed to save session for \(contactId): \(error.localizedDescription)")
        }
    }

    public func loadAllSessions() {
        let dir = Self.sessionsDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "enc" {
            let contactId = file.deletingPathExtension().lastPathComponent
            do {
                let data = try encryptor.readAndDecrypt(from: file)
                let session = try JSONDecoder().decode(DoubleRatchetSession.self, from: data)
                sessions[contactId] = session
                Self.logger.info("Loaded session for \(contactId)")
            } catch {
                Self.logger.error("Failed to load session \(contactId): \(error.localizedDescription)")
            }
        }
    }

    public func deleteSession(for contactId: String) {
        sessions.removeValue(forKey: contactId)
        let url = Self.sessionsDirectory.appendingPathComponent("\(contactId).enc")
        try? FileManager.default.removeItem(at: url)
    }

    public func migrateSessionKey(from oldKey: String, to newKey: String) {
        guard let session = sessions.removeValue(forKey: oldKey) else { return }
        sessions[newKey] = session
        deleteSession(for: oldKey)
        saveSession(for: newKey)
    }

    public enum RemoteSessionError: Error {
        case invalidSignedPreKey
        case unknownSignedPreKey
        case noSession
    }
}
