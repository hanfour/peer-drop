import Foundation
import PeerDropSecurity

// MARK: - MailboxServiceProtocol conformance

/// Adapts `MailboxClient` to `MailboxServiceProtocol` so `RemoteSessionManager`
/// can call `fetchSecurityPreKeyBundle` without a direct dependency on the Transport layer.
extension MailboxClient: MailboxServiceProtocol {

    /// Fetches the peer's pre-key bundle and converts `FetchedPreKeyBundle`
    /// (Transport's wire format) into `PreKeyBundle` (Security's domain type).
    /// The single-OPK field from the wire bundle is wrapped in a 0-or-1 array.
    public func fetchSecurityPreKeyBundle(mailboxId: String) async throws -> PreKeyBundle {
        let fetched = try await fetchPreKeyBundle(mailboxId: mailboxId)
        return PreKeyBundle(
            identityKey: fetched.identityKey,
            signingKey: fetched.signingKey,
            signedPreKey: fetched.signedPreKey,
            oneTimePreKeys: fetched.oneTimePreKey.map { [$0] } ?? [],
            signedPreKeyTimestamp: fetched.signedPreKeyTimestamp,
            signedPreKeyTimestampSignature: fetched.signedPreKeyTimestampSignature
        )
    }
}
