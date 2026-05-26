import Foundation

/// Minimal mailbox interface required by `RemoteSessionManager`.
/// Implemented by `MailboxClient` in the Transport layer via a conformance
/// extension in `PeerDrop/Transport/MailboxClient+SecurityProtocol.swift`.
///
/// The returned `PreKeyBundle` uses `oneTimePreKeys` (array) — the
/// conforming adapter picks the first available OPK from the fetched bundle.
public protocol MailboxServiceProtocol: Actor {
    /// Fetch a peer's pre-key bundle for X3DH session initiation.
    func fetchSecurityPreKeyBundle(mailboxId: String) async throws -> PreKeyBundle
}
