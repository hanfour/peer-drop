import Foundation

/// Wire payload for uploading a `CryptoHardeningMetrics.Snapshot` to the
/// worker's `POST /debug/crypto-metric` endpoint (v5.4 soak, spec §8.6).
///
/// Pure/value type so it's trivially unit-testable without a network leg
/// — the actual POST lives in `CryptoMetricsUploader` (PeerDropCore).
/// The JSON shape matches what the worker validates: a top-level
/// `counters` object plus the per-peer-version `keyedCounters` array.
public struct CryptoMetricsPayload: Encodable {

    /// Flat counters keyed by event kind (e.g. "c1.spk_timestamp_valid").
    public let counters: [String: Int]

    /// Per-(kind, peerVersion) counters — retains the dimension the spec
    /// needs to attribute events to legacy vs v5.4+ peers.
    public let keyedCounters: [KeyedCounter]

    public let platform: String
    public let appVersion: String
    /// ISO-8601 capture time.
    public let timestamp: String

    public struct KeyedCounter: Encodable {
        public let kind: String
        public let peerVersion: String?
        public let count: Int
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Returns nil when the snapshot is empty — an empty snapshot carries
    /// no information and must not be POSTed (keeps idle devices silent).
    public init?(
        snapshot: CryptoHardeningMetrics.Snapshot,
        platform: String,
        appVersion: String,
        timestamp: Date
    ) {
        guard !snapshot.counters.isEmpty else { return nil }
        self.counters = snapshot.counters
        self.keyedCounters = snapshot.keyedCounters.map { key, count in
            KeyedCounter(kind: key.kind, peerVersion: key.peerVersion, count: count)
        }
        self.platform = platform
        self.appVersion = appVersion
        self.timestamp = Self.isoFormatter.string(from: timestamp)
    }
}
