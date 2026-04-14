import Foundation
import CryptoKit
import os.log

/// Manages encrypted remote sessions with peers via X3DH + Double Ratchet.
/// Coordinates with MailboxClient for message delivery and PreKeyStore for key material.
@MainActor
final class RemoteSessionManager: ObservableObject {

    private static let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "RemoteSessionManager")

    private var sessions: [String: DoubleRatchetSession] = [:] // keyed by contact UUID
    private let preKeyStore: PreKeyStore
    private let mailboxClient: MailboxClient

    init(preKeyStore: PreKeyStore = PreKeyStore(), mailboxClient: MailboxClient = MailboxClient()) {
        self.preKeyStore = preKeyStore
        self.mailboxClient = mailboxClient
    }

    // MARK: - Initiate Session (Alice side)

    func initiateSession(
        contactId: String,
        peerMailboxId: String
    ) async throws -> DoubleRatchetSession {
        let bundle = try await mailboxClient.fetchPreKeyBundle(mailboxId: peerMailboxId)

        // Validate signed pre-key signature
        let signingPub = try Curve25519.Signing.PublicKey(rawRepresentation: bundle.signingKey)
        guard bundle.signedPreKey.verify(with: signingPub) else {
            throw RemoteSessionError.invalidSignedPreKey
        }

        let theirIdentityKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: bundle.identityKey)
        let theirSignedPreKey = try bundle.signedPreKey.agreementPublicKey()

        var theirOneTimePreKey: Curve25519.KeyAgreement.PublicKey?
        if let otpk = bundle.oneTimePreKey {
            theirOneTimePreKey = try otpk.agreementPublicKey()
        }

        let ephemeralKey = Curve25519.KeyAgreement.PrivateKey()
        let x3dhResult = try X3DH.initiatorKeyAgreement(
            myIdentityKey: IdentityKeyManager.shared.agreementPrivateKeyForX3DH(),
            myEphemeralKey: ephemeralKey,
            theirIdentityKey: theirIdentityKey,
            theirSignedPreKey: theirSignedPreKey,
            theirOneTimePreKey: theirOneTimePreKey
        )

        let session = DoubleRatchetSession.initializeAsInitiator(
            rootKey: x3dhResult.rootKey,
            theirRatchetKey: theirSignedPreKey
        )

        sessions[contactId] = session
        Self.logger.info("Remote session initiated with contact \(contactId)")
        return session
    }

    // MARK: - Respond to Session (Bob side)

    func respondToSession(
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
        Self.logger.info("Remote session established as responder for contact \(contactId)")
        return session
    }

    // MARK: - Encrypt / Decrypt

    func encrypt(data: Data, for contactId: String) throws -> RatchetMessage {
        guard let session = sessions[contactId] else {
            throw RemoteSessionError.noSession
        }
        return try session.encrypt(data)
    }

    func decrypt(message: RatchetMessage, from contactId: String) throws -> Data {
        guard let session = sessions[contactId] else {
            throw RemoteSessionError.noSession
        }
        return try session.decrypt(message)
    }

    func hasSession(for contactId: String) -> Bool {
        sessions[contactId] != nil
    }

    enum RemoteSessionError: Error {
        case invalidSignedPreKey
        case unknownSignedPreKey
        case noSession
    }
}
