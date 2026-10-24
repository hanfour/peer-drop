import Foundation

/// Chat-thread storage key for messages arriving on a connection.
///
/// A relay connection is installed as `relay-<code>` with a placeholder
/// identity; the peer's first HELLO swaps in its real identity, and every UI
/// surface (and every outgoing save) addresses the peer by that identity UUID.
/// Incoming messages used to be stored under the connection id, splitting the
/// thread in two. Relay connections now store under `peerIdentity.id` once
/// known (before the HELLO swap the identity is still the placeholder, whose id
/// equals the connection id, so the key falls back to the connection id).
/// Non-relay connections are unchanged. Old `relay-` chat files are not migrated.
@MainActor
public enum ChatStorageKey {
    static func key(forConnection pc: PeerConnection) -> String {
        if pc.isRelayTransport || pc.id.hasPrefix("relay-") {
            return pc.peerIdentity.id
        }
        return pc.id
    }
}
