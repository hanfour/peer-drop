import Foundation
import os.log

actor ConnectionMetrics {
    static let shared = ConnectionMetrics()

    private static let configCacheKey = "peerDropMetricsConfig"

    private let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "ConnectionMetrics")
    private var buffer: [ConnectionMetric] = []
    private let flushThreshold: Int
    private let maxBufferSize = 500
    private var remoteConfig: RemoteConfig = .default

    // Test-observable state (read via actor-isolated getters).
    private(set) var recordedCount: Int = 0
    private(set) var lastRecordedMetric: ConnectionMetric?
    private(set) var droppedCount: Int = 0  // overflow + sampling drops
    private var didWarnFlushError: Bool = false
    private var didWarnConfigFetchError: Bool = false

    init(flushOnCount: Int = 50) {
        self.flushThreshold = flushOnCount
        // Load cached config from previous session so cold starts honor the last-known state.
        if let cached = UserDefaults.standard.data(forKey: Self.configCacheKey),
           let config = try? JSONDecoder().decode(RemoteConfig.self, from: cached) {
            self.remoteConfig = config
        }
    }

    var pendingCount: Int { buffer.count }

    /// Test-only observation of the current remote config.
    var currentConfig: RemoteConfig { remoteConfig }

    struct RemoteConfig: Codable {
        let sampleRate: Double
        let enabled: Bool
        static let `default` = RemoteConfig(sampleRate: 1.0, enabled: true)
    }

    /// Snapshot of a token's mutable state captured at finalize time.
    /// Passed by value into the actor so that deinit-path scheduling does not
    /// need to retain the Token reference itself.
    fileprivate struct TokenSnapshot {
        let id: String
        let startedAt: Date
        let type: ConnectionMetric.ConnectionType
        let role: ConnectionMetric.Role
        let gathered: [ConnectionMetric.CandidateType]
        let srflxOrder: Int?
        let relayOrder: Int?
        let phase1Ms: Int?
        let phase2Ms: Int?
        let ipv6Gathered: Bool
        let ipv6Connected: Bool
    }

    /// Opaque handle for one in-flight connection attempt. If this is deallocated
    /// without `recordConnected` or `recordFailure` being called, the actor records
    /// the metric as `.abandoned` on the next event-loop tick.
    final class Token {
        let id = UUID().uuidString
        let startedAt = Date()
        let type: ConnectionMetric.ConnectionType
        let role: ConnectionMetric.Role

        fileprivate var gathered: [ConnectionMetric.CandidateType] = []
        fileprivate var srflxOrder: Int?
        fileprivate var relayOrder: Int?
        fileprivate var phase1Ms: Int?
        fileprivate var phase2Ms: Int?
        fileprivate var ipv6Gathered: Bool = false
        fileprivate var ipv6Connected: Bool = false
        // NOTE: `finalized` is read non-atomically from deinit (which runs on the
        // thread dropping the last reference). This is safe provided callers release
        // their Token reference only from a context that has awaited the finalize
        // call. If Tokens start being passed across async boundaries without this
        // discipline, upgrade `finalized` to `OSAllocatedUnfairLock<Bool>` or similar.
        fileprivate var finalized: Bool = false
        // Invoked from deinit with a value-type snapshot — avoids retaining `self`.
        fileprivate var onDeinit: ((TokenSnapshot) -> Void)?

        fileprivate init(type: ConnectionMetric.ConnectionType, role: ConnectionMetric.Role) {
            self.type = type
            self.role = role
        }

        fileprivate func snapshot() -> TokenSnapshot {
            TokenSnapshot(
                id: id,
                startedAt: startedAt,
                type: type,
                role: role,
                gathered: gathered,
                srflxOrder: srflxOrder,
                relayOrder: relayOrder,
                phase1Ms: phase1Ms,
                phase2Ms: phase2Ms,
                ipv6Gathered: ipv6Gathered,
                ipv6Connected: ipv6Connected
            )
        }

        deinit {
            guard !finalized, let cb = onDeinit else { return }
            cb(snapshot())
        }
    }

    func begin(type: ConnectionMetric.ConnectionType, role: ConnectionMetric.Role) -> Token {
        let t = Token(type: type, role: role)
        t.onDeinit = { [weak self] snap in
            Task { await self?.recordAbandoned(snap) }
        }
        return t
    }

    func recordICEGather(_ token: Token, candidate: ConnectionMetric.CandidateType, order: Int, isIPv6: Bool = false) {
        token.gathered.append(candidate)
        if candidate == .srflx, token.srflxOrder == nil { token.srflxOrder = order }
        if candidate == .relay, token.relayOrder == nil { token.relayOrder = order }
        if isIPv6 { token.ipv6Gathered = true }
    }

    func recordConnected(_ token: Token, used: ConnectionMetric.CandidateType, ipv6Connected: Bool = false) async {
        guard !token.finalized else { return }
        token.finalized = true
        token.ipv6Connected = ipv6Connected
        await finalize(snapshot: token.snapshot(), outcome: .success, used: used)
    }

    func recordFailure(_ token: Token, reason: String) async {
        guard !token.finalized else { return }
        token.finalized = true
        await finalize(snapshot: token.snapshot(), outcome: .failure(reason: reason), used: nil)
    }

    func recordPhaseTime(_ token: Token, phase: Int, elapsedMs: Int) {
        guard !token.finalized else { return }
        if phase == 1 {
            token.phase1Ms = elapsedMs
        } else {
            token.phase2Ms = elapsedMs
        }
    }

    private func recordAbandoned(_ snapshot: TokenSnapshot) async {
        await finalize(snapshot: snapshot, outcome: .abandoned, used: nil)
    }

    func updateRemoteConfig(_ cfg: RemoteConfig) {
        remoteConfig = cfg
    }

    /// Fetch the current remote config from the Worker. On success, update the
    /// in-memory value AND persist to UserDefaults so cold starts after network
    /// loss still honor the last good state. On failure, keep whatever is cached.
    func fetchRemoteConfig() async {
        let baseURL = UserDefaults.standard.string(forKey: "peerDropWorkerURL")
            ?? "https://peerdrop-signal.hanfourhuang.workers.dev"
        guard let url = URL(string: "\(baseURL)/config/metrics") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                if !didWarnConfigFetchError {
                    didWarnConfigFetchError = true
                    logger.warning("First metrics config fetch error: non-200 status \(status). Subsequent errors suppressed to .debug.")
                } else {
                    logger.debug("metrics config fetch error: non-200 status \(status)")
                }
                return
            }
            let cfg = try JSONDecoder().decode(RemoteConfig.self, from: data)
            self.remoteConfig = cfg
            if let encoded = try? JSONEncoder().encode(cfg) {
                UserDefaults.standard.set(encoded, forKey: Self.configCacheKey)
            }
            logger.info("metrics config refreshed: sampleRate=\(cfg.sampleRate) enabled=\(cfg.enabled)")
        } catch {
            if !didWarnConfigFetchError {
                didWarnConfigFetchError = true
                logger.warning("First metrics config fetch error: \(error.localizedDescription). Subsequent errors suppressed to .debug.")
            } else {
                logger.debug("metrics config fetch error: \(error.localizedDescription)")
            }
            // Keep the cached value — do not reset to default.
        }
    }

    // MARK: - Private

    private func finalize(snapshot: TokenSnapshot, outcome: ConnectionMetric.Outcome, used: ConnectionMetric.CandidateType?) async {
        // Apply sampling + enabled gate BEFORE buffering.
        guard remoteConfig.enabled else {
            droppedCount += 1
            return
        }
        guard remoteConfig.sampleRate > 0 else {
            droppedCount += 1
            return
        }
        if remoteConfig.sampleRate < 1.0,
           Double.random(in: 0..<1) >= remoteConfig.sampleRate {
            droppedCount += 1
            return
        }

        let stats = ConnectionMetric.ICEStats(
            candidatesGathered: snapshot.gathered,
            candidatesUsed: used,
            srflxGatherOrder: snapshot.srflxOrder,
            relayGatherOrder: snapshot.relayOrder,
            firstConnectedMs: nil,
            phase1ConnectedMs: snapshot.phase1Ms,
            phase2ConnectedMs: snapshot.phase2Ms,
            ipv6CandidateGathered: snapshot.ipv6Gathered,
            ipv6Connected: snapshot.ipv6Connected
        )
        let durationMs = Int(Date().timeIntervalSince(snapshot.startedAt) * 1000)
        let metric = ConnectionMetric(
            id: snapshot.id,
            timestamp: Date(),
            connectionType: snapshot.type,
            role: snapshot.role,
            outcome: outcome,
            durationMs: durationMs,
            iceStats: stats,
            platform: "ios",
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            networkType: .unknown,
            hasTailscale: false,
            hasIPv6: false
        )

        buffer.append(metric)
        if buffer.count > maxBufferSize {
            let overflow = buffer.count - maxBufferSize
            buffer.removeFirst(overflow)
            droppedCount += overflow
        }
        lastRecordedMetric = metric
        recordedCount += 1
        if buffer.count >= flushThreshold {
            await flush()
        }
    }

    /// Post buffered metrics to the Worker, one per request. Drops on any
    /// non-success status — the design doc's "no queue" policy: an unreliable
    /// device's telemetry loss is acceptable; a persistent on-device queue is not.
    func flush() async {
        let batch = buffer
        buffer.removeAll(keepingCapacity: true)
        guard !batch.isEmpty else { return }

        let baseURL = UserDefaults.standard.string(forKey: "peerDropWorkerURL")
            ?? "https://peerdrop-signal.hanfourhuang.workers.dev"
        guard let url = URL(string: "\(baseURL)/debug/metric") else { return }
        let apiKey = Bundle.main.object(forInfoDictionaryKey: "PeerDropWorkerAPIKey") as? String
        guard let apiKey, !apiKey.isEmpty else {
            logger.debug("Skipping flush: PeerDropWorkerAPIKey not set (e.g. unit-test or config missing)")
            return
        }
        let encoder = ConnectionMetric.makeEncoder()

        for metric in batch {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
            request.timeoutInterval = 10
            do {
                request.httpBody = try encoder.encode(metric)
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode != 201 {
                    if !didWarnFlushError {
                        didWarnFlushError = true
                        logger.warning("First metric POST non-201: \(http.statusCode). Subsequent errors suppressed to .debug.")
                    } else {
                        logger.debug("metric POST non-201: \(http.statusCode)")
                    }
                }
            } catch {
                if !didWarnFlushError {
                    didWarnFlushError = true
                    logger.warning("First metric POST failed: \(error.localizedDescription). Subsequent errors suppressed to .debug.")
                } else {
                    logger.debug("metric POST failed: \(error.localizedDescription)")
                }
            }
        }
    }
}
