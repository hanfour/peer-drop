import Foundation
import CryptoKit

// MARK: - NetworkFingerprint

/// Produces a stable 8-hex-char identifier for a network, keyed by (subnet, gateway).
enum NetworkFingerprint {
    static func fingerprint(subnet: String, gateway: String) -> String {
        let input = "\(subnet)|\(gateway)"
        let hash = SHA256.hash(data: Data(input.utf8))
        return hash.prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - RelayHintsStore

/// Tracks how often a given network fingerprint required phase-2 (relay) rescue.
/// After 3 consecutive phase-2 successes on the same fingerprint, `shouldPreferRelay` returns true.
/// A single phase-1 success resets the counter.
final class RelayHintsStore {
    static let shared = RelayHintsStore()
    private let key = "peerDropRelayHints"

    private var hints: [String: Int] {
        get { (UserDefaults.standard.dictionary(forKey: key) as? [String: Int]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    func shouldPreferRelay(fingerprint: String) -> Bool {
        (hints[fingerprint] ?? 0) >= 3
    }

    func recordPhase2Save(fingerprint: String) {
        var h = hints
        h[fingerprint] = (h[fingerprint] ?? 0) + 1
        hints = h
    }

    func recordPhase1Success(fingerprint: String) {
        var h = hints
        h[fingerprint] = 0
        hints = h
    }
}
