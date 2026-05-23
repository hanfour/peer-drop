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
