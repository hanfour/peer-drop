import Foundation
import PeerDropSecurity
import PeerDropNotes

/// Production `NotesCryptoContext`: the device identity from
/// `IdentityKeyManager.shared` and pre-keys from the app's single
/// `PreKeyStore` (the same instance MailboxManager uploads from — a
/// different instance would hold different keys and nothing would decrypt).
struct LiveNotesCryptoContext: NotesCryptoContext, @unchecked Sendable {
    let preKeyStore: PreKeyStore

    func recipientKeys() throws -> NoteRecipientKeys {
        NoteRecipientKeys(
            identityKey: IdentityKeyManager.shared.agreementPrivateKeyForX3DH(),
            signedPreKey: { id in try preKeyStore.signedPreKey(for: id) },
            oneTimePreKey: { id in try preKeyStore.consumeOneTimePreKey(id: id) })
    }

    func signer(accountId: String, nickname: String?) throws -> NoteSigner {
        NoteSigner(accountId: accountId, nickname: nickname,
                   signingPublicKey: IdentityKeyManager.shared.signingPublicKey.rawRepresentation,
                   sign: { try IdentityKeyManager.shared.sign($0) })
    }
}
