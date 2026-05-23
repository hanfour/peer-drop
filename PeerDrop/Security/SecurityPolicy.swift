import Foundation

/// Immutable value type holding all tunable crypto-hardening thresholds.
/// Read at every relevant call site; never mutated in-place. Merging is
/// always stronger-of-two — see `merged(local:remote:)`.
public struct SecurityPolicy: Equatable, Codable {

    public enum OPKExhaustionBehavior: String, Codable, Comparable {
        /// Current pre-v5.4 behavior: skip DH4 and proceed with weakened
        /// forward secrecy.
        case proceedWithoutDH4

        /// v5.4+ behavior: refuse to initiate X3DH, schedule retry.
        case failClosed

        /// Strictness ordering: failClosed > proceedWithoutDH4.
        public static func < (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.proceedWithoutDH4, .failClosed): return true
            default: return false
            }
        }
    }
}
