import Foundation
import CryptoKit
import PeerDropSecurity
import PeerDropTransport
import PeerDropAccount
@testable import PeerDropNotes
@testable import PeerDropDiary

/// A directory recipient built from raw CryptoKit keys — no keychain, no
/// PreKeyStore — so `DiaryKeyRelay` can seal a real `NoteCrypto` envelope
/// to it under plain `swift test`. Trimmed copy of
/// `PeerDropNotesTests/RecipientFixture` (only the pieces `DiaryKeyRelay`
/// actually exercises).
struct DiaryRecipientFixture {
    let accountId = AccountID(raw: "NEWMEMBR")!
    let identity = Curve25519.KeyAgreement.PrivateKey()
    let signing = Curve25519.Signing.PrivateKey()
    let spk: SignedPreKey
    let opk = OneTimePreKey.generate(id: 41)

    init() throws {
        let kp = Curve25519.KeyAgreement.PrivateKey()
        spk = SignedPreKey(id: 7, publicKey: kp.publicKey.rawRepresentation, privateKey: kp.rawRepresentation,
                           signature: try signing.signature(for: kp.publicKey.rawRepresentation), timestamp: Date())
    }

    /// Includes the C1 timestamp attestation, which classifies this peer as
    /// `.v5_4_plus` (strict OPK policy) — so the bundle MUST carry an OPK
    /// (`RecipientFixture`'s own doc comment: "v54: true adds the C1
    /// timestamp attestation (peer classified .v5_4_plus, strict OPK
    /// policy)"), or `NoteCrypto.seal` throws `.opkExhausted`.
    func entry(now: Date = Date()) throws -> DirectoryEntry {
        let t = UInt64(now.timeIntervalSince1970)
        var payload = spk.publicKey
        var be = t.bigEndian
        payload.append(Data(bytes: &be, count: 8))
        let tsSig = try signing.signature(for: payload)
        let spkPublic = PublicSignedPreKey(id: spk.id, publicKey: spk.publicKey, signature: spk.signature, timestamp: spk.timestamp)
        let bundle = FetchedPreKeyBundle(identityKey: identity.publicKey.rawRepresentation, signingKey: signing.publicKey.rawRepresentation,
                                         signedPreKey: spkPublic, oneTimePreKey: PublicOneTimePreKey(id: opk.id, publicKey: opk.publicKey),
                                         signedPreKeyTimestamp: t, signedPreKeyTimestampSignature: tsSig)
        return DirectoryEntry(accountId: accountId, nickname: "newmember", identityKey: identity.publicKey.rawRepresentation,
                              signingKey: signing.publicKey.rawRepresentation, mailboxId: "mbxnew", preKeyBundle: bundle)
    }

    /// Keys as the recipient device would supply them, for opening an
    /// envelope this fixture's `entry()` was the recipient of.
    func keys() -> NoteRecipientKeys {
        NoteRecipientKeys(identityKey: identity,
                          signedPreKey: { id in id == self.spk.id ? self.spk : nil },
                          oneTimePreKey: { id in id == self.opk.id ? self.opk : nil })
    }

    /// The wire JSON `GET /v3/directory/<handle>?bundle=1` would answer with.
    func directoryJSON() throws -> Data {
        let entry = try self.entry()
        let bundle = entry.preKeyBundle!
        return Data(#"""
        {"accountId":"\#(entry.accountId.raw)","nickname":"newmember","identityKey":"\#(entry.identityKey.base64EncodedString())","signingKey":"\#(entry.signingKey.base64EncodedString())","mailboxId":"mbxnew","preKeyBundle":\#(String(decoding: try JSONEncoder().encode(bundle), as: UTF8.self))}
        """#.utf8)
    }
}

/// `NotesCryptoContext` that signs with a fixed device identity — used
/// wherever `DiaryKeyRelay`/`DiaryStore` needs to seal a `diaryKey` note as
/// this device.
struct DiaryFakeCrypto: NotesCryptoContext {
    let signing = Curve25519.Signing.PrivateKey()
    func recipientKeys() throws -> NoteRecipientKeys {
        throw NotesStoreError.noAccount   // DiaryKeyRelay/DiaryStore never decrypt as a note recipient
    }
    func signer(accountId: String, nickname: String?) throws -> NoteSigner {
        NoteSigner(accountId: accountId, nickname: nickname, signingPublicKey: signing.publicKey.rawRepresentation,
                  sign: { try self.signing.signature(for: $0) })
    }
}
