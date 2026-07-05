import Foundation
import Combine

/// Per-process counter store for the 23 crypto-hardening events (spec §8.1
/// baseline of 22, + `policy.invariant_violation` added in PR4 review).
/// Counters are keyed by `(kind, peerVersion)` so the flushed snapshot
/// retains the per-peer-version dimension the spec requires.
/// Thread-safe via NSLock. Snapshots flush through the
/// existing ConnectionMetrics pipeline (wired in Task 1.10).
///
/// Conforms to `ObservableObject` so it can be held as a `@StateObject`
/// and distributed via `.environmentObject()` in the SwiftUI hierarchy.
/// No `@Published` properties are needed — consumers read via `snapshot()`.
public final class CryptoHardeningMetrics: ObservableObject {

    public enum EventKind: String, CaseIterable {
        // C1 (5)
        case c1SpkTimestampMissing            = "c1.spk_timestamp_missing"
        case c1SpkTimestampMalformed          = "c1.spk_timestamp_malformed"
        case c1SpkTimestampInvalidSignature   = "c1.spk_timestamp_invalid_signature"
        case c1SpkTimestampTooOld             = "c1.spk_timestamp_too_old"
        case c1SpkTimestampValid              = "c1.spk_timestamp_valid"

        // C2 (4)
        case c2OpkMissing                     = "c2.opk_missing"
        case c2OpkFailedInitiation            = "c2.opk_failed_initiation"
        case c2OpkRetrySucceeded              = "c2.opk_retry_succeeded"
        case c2OpkRetryExhausted              = "c2.opk_retry_exhausted"

        // C3 (4)
        case c3SkippedKeyEvictedTTL           = "c3.skipped_key_evicted_ttl"
        case c3SkippedKeyEvictedLRU           = "c3.skipped_key_evicted_lru"
        case c3SkippedKeyHit                  = "c3.skipped_key_hit"
        case c3SkippedKeyMiss                 = "c3.skipped_key_miss"

        // C4 (2)
        case c4ConsumedOpkPruned              = "c4.consumed_opk_pruned"
        case c4ConsumedOpkSize                = "c4.consumed_opk_size"

        // policy (8)
        case policyFetchSuccess               = "policy.fetch_success"
        case policyFetchFailure               = "policy.fetch_failure"
        case policySignatureInvalid           = "policy.signature_invalid"
        case policyVersionUnsupported         = "policy.version_unsupported"
        case policyValueOutOfBounds           = "policy.value_out_of_bounds"
        case policyCacheHit                   = "policy.cache_hit"
        case policyExpiredInUse               = "policy.expired_in_use"
        /// A validly-signed blob whose policy violates a cross-field invariant
        /// (e.g., `consumedOPKPruneWindow < spkMaxAge * 4`). Distinct from
        /// `policyFetchFailure` (network) and `policySignatureInvalid` (tampering)
        /// — this event signals operator misconfiguration or signed-key-with-bad-payload.
        case policyInvariantViolation         = "policy.invariant_violation"
    }

    public struct Key: Hashable {
        public let kind: String
        public let peerVersion: String?   // PeerVersion.rawValue or nil

        public init(kind: String, peerVersion: String?) {
            self.kind = kind
            self.peerVersion = peerVersion
        }
    }

    public struct Snapshot {
        /// Flat counters by "kind" only — easy aggregate view used by tests
        /// and the simplest dashboard.
        public let counters: [String: Int]
        /// Counters keyed by both kind and peer version (when known).
        /// Sent to the worker as the canonical telemetry payload.
        public let keyedCounters: [Key: Int]
    }

    private let lock = NSLock()
    private var keyedCounters: [Key: Int] = [:]

    /// Optional disk backing so undelivered counters survive OS termination.
    /// nil ⇒ pure in-memory (tests, and any consumer that doesn't need the
    /// at-least-once soak guarantee).
    private let persistenceURL: URL?

    public init() {
        self.persistenceURL = nil
    }

    /// Persistence-enabled init: loads any residual counters left by a prior
    /// launch (an undelivered soak batch the OS killed before re-flush).
    public init(persistenceURL: URL?) {
        self.persistenceURL = persistenceURL
        if let url = persistenceURL {
            loadFromDisk(url)
        }
    }

    /// On-disk form: a flat list of (kind, peerVersion, count) rows.
    private struct DiskRow: Codable {
        let kind: String
        let peerVersion: String?
        let count: Int
    }

    /// Write the current counters to `persistenceURL`. No-op when persistence
    /// is disabled. Call AFTER an upload's subtract so only the undelivered
    /// residual is persisted. Failures are swallowed — telemetry durability
    /// is best-effort and must never disrupt the app.
    public func persist() {
        guard let url = persistenceURL else { return }
        lock.lock()
        let rows = keyedCounters.map { DiskRow(kind: $0.key.kind, peerVersion: $0.key.peerVersion, count: $0.value) }
        lock.unlock()
        guard let data = try? JSONEncoder().encode(rows) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func loadFromDisk(_ url: URL) {
        guard let data = try? Data(contentsOf: url),
              let rows = try? JSONDecoder().decode([DiskRow].self, from: data) else { return }
        lock.lock()
        defer { lock.unlock() }
        for row in rows where row.count > 0 {
            keyedCounters[Key(kind: row.kind, peerVersion: row.peerVersion), default: 0] += row.count
        }
    }

    public func record(_ kind: EventKind, peerVersion: PeerVersion? = nil) {
        lock.lock()
        defer { lock.unlock() }
        let key = Key(kind: kind.rawValue, peerVersion: peerVersion?.rawValue)
        keyedCounters[key, default: 0] += 1
    }

    public func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        var flat: [String: Int] = [:]
        for (key, count) in keyedCounters {
            flat[key.kind, default: 0] += count
        }
        return Snapshot(counters: flat, keyedCounters: keyedCounters)
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        keyedCounters.removeAll()
    }

    /// Remove exactly the counts captured in `delivered`, clamping at zero
    /// and dropping keys that reach zero. Used by the metrics uploader for
    /// at-least-once soak delivery: it snapshots, POSTs, and only on a 2xx
    /// subtracts the delivered counts — so events recorded during the
    /// in-flight POST are preserved, and a failed POST's counts are re-sent
    /// on the next flush rather than silently lost.
    public func subtract(_ delivered: Snapshot) {
        lock.lock()
        defer { lock.unlock() }
        for (key, count) in delivered.keyedCounters {
            guard let current = keyedCounters[key] else { continue }
            let remaining = current - count
            if remaining > 0 {
                keyedCounters[key] = remaining
            } else {
                keyedCounters[key] = nil
            }
        }
    }
}
