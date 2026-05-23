import Foundation

/// Identifies the protocol generation of a peer for per-peer policy
/// decisions. v5.0–v5.3.x are `.legacy`; v5.4+ are `.v5_4_plus`;
/// `.unknown` is used before first contact or when the peer hasn't sent
/// any envelope yet.
///
/// Distinct from the `ProtocolVersion` UInt8 enum in `PeerDrop/Protocol/`
/// which identifies the wire envelope format version.
public enum PeerVersion: String, Codable {
    case legacy
    case v5_4_plus
    case unknown
}

extension PeerVersion {
    /// Map a `RemoteMessageEnvelope.protocolVersion` byte to a `PeerVersion`.
    /// - `nil` → `.legacy` (sender is v5.0–v5.3.x; field absent)
    /// - `1`   → `.v5_4_plus`
    /// - anything else → `.unknown` (future schema we don't yet handle)
    public static func from(envelopeProtocolVersion: UInt8?) -> PeerVersion {
        switch envelopeProtocolVersion {
        case nil:        return .legacy
        case 1:          return .v5_4_plus
        default:         return .unknown
        }
    }
}
