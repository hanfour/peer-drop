import Foundation
import CryptoKit

extension PeerConnection {
    /// Raw bytes of the identity key the peer ACTUALLY used in the
    /// `LocalSecureChannel` handshake (nil until the channel is established).
    ///
    /// This can differ from `peerIdentity.identityPublicKey`, which is only
    /// what the peer *claimed* in its hello. Pinning (`pinningVerdict`) is
    /// computed off the hello key, so callers that grant privileges — e.g.
    /// peerdrop-cli writing peer text into a shell — must also require the
    /// two keys to be identical. Read-only; lives in an extension so it does
    /// not touch the connection's state machine.
    public var handshakePeerIdentityKey: Data? {
        secureChannel?.peerIdentityPublicKey.rawRepresentation
    }
}
