import Foundation
import CryptoKit
import PeerDropSecurity
import PeerDropTransport
import PeerDropAccount
@testable import PeerDropNotes

/// A recipient built from raw CryptoKit keys — no keychain, no PreKeyStore,
/// so these tests run under plain `swift test`.
struct RecipientFixture {
    let accountId = AccountID(raw: "TESTRCPT")!
    let identity = Curve25519.KeyAgreement.PrivateKey()
    let signing = Curve25519.Signing.PrivateKey()
    let spk: SignedPreKey
    let opk = OneTimePreKey.generate(id: 41)

    init() throws {
        let kp = Curve25519.KeyAgreement.PrivateKey()
        spk = SignedPreKey(id: 7, publicKey: kp.publicKey.rawRepresentation, privateKey: kp.rawRepresentation,
                           signature: try signing.signature(for: kp.publicKey.rawRepresentation), timestamp: Date())
    }

    /// `v54: true` adds the C1 timestamp attestation (peer classified `.v5_4_plus`,
    /// strict OPK policy); `false` leaves both fields nil (`.legacy`).
    func entry(withOPK: Bool = true, v54: Bool = true, badSPKSignature: Bool = false, now: Date = Date()) throws -> DirectoryEntry {
        var ts: UInt64? = nil, tsSig: Data? = nil
        if v54 {
            let t = UInt64(now.timeIntervalSince1970)
            var payload = spk.publicKey
            var be = t.bigEndian
            payload.append(Data(bytes: &be, count: 8))
            ts = t; tsSig = try signing.signature(for: payload)
        }
        let spkPublic = PublicSignedPreKey(id: spk.id, publicKey: spk.publicKey, signature: badSPKSignature ? Data(repeating: 1, count: 64) : spk.signature, timestamp: spk.timestamp)
        let bundle = FetchedPreKeyBundle(identityKey: identity.publicKey.rawRepresentation, signingKey: signing.publicKey.rawRepresentation,
                                         signedPreKey: spkPublic, oneTimePreKey: withOPK ? PublicOneTimePreKey(id: opk.id, publicKey: opk.publicKey) : nil,
                                         signedPreKeyTimestamp: ts, signedPreKeyTimestampSignature: tsSig)
        return DirectoryEntry(accountId: accountId, nickname: "rcpt", identityKey: identity.publicKey.rawRepresentation,
                              signingKey: signing.publicKey.rawRepresentation, mailboxId: "mbxtest", preKeyBundle: bundle)
    }

    /// Keys as the recipient device would supply them. `opkAvailable: false`
    /// simulates an already-consumed one-time pre-key.
    func keys(opkAvailable: Bool = true) -> NoteRecipientKeys {
        NoteRecipientKeys(identityKey: identity,
                          signedPreKey: { id in id == self.spk.id ? self.spk : nil },
                          oneTimePreKey: { id in (opkAvailable && id == self.opk.id) ? self.opk : nil })
    }
}

struct SenderFixture {
    let accountId = "SENDR001"
    let signing = Curve25519.Signing.PrivateKey()
    var signer: NoteSigner {
        NoteSigner(accountId: accountId, nickname: "alice", signingPublicKey: signing.publicKey.rawRepresentation, sign: { try self.signing.signature(for: $0) })
    }
}
