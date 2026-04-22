import Foundation
import os.log

actor ConnectionMetrics {
    static let shared = ConnectionMetrics()

    private let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "ConnectionMetrics")
    private var buffer: [ConnectionMetric] = []
    private let flushThreshold: Int
    private var remoteConfig: RemoteConfig = .default

    // Test-observable state (read via actor-isolated getters).
    private(set) var lastFlushedCount: Int = 0
    private(set) var lastFlushedMetric: ConnectionMetric?

    init(flushOnCount: Int = 50) {
        self.flushThreshold = flushOnCount
    }

    var pendingCount: Int { buffer.count }

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

    private func recordAbandoned(_ snapshot: TokenSnapshot) async {
        await finalize(snapshot: snapshot, outcome: .abandoned, used: nil)
    }

    func updateRemoteConfig(_ cfg: RemoteConfig) {
        remoteConfig = cfg
    }

    // MARK: - Private

    private func finalize(snapshot: TokenSnapshot, outcome: ConnectionMetric.Outcome, used: ConnectionMetric.CandidateType?) async {
        // Apply sampling + enabled gate BEFORE buffering.
        guard remoteConfig.enabled else { return }
        guard remoteConfig.sampleRate > 0 else { return }
        if remoteConfig.sampleRate < 1.0,
           Double.random(in: 0..<1) >= remoteConfig.sampleRate {
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
        lastFlushedMetric = metric
        lastFlushedCount += 1
        if buffer.count >= flushThreshold {
            await flush()
        }
    }

    /// Stub — Task 2.3 will post the batch to the Worker.
    func flush() async {
        let batch = buffer
        buffer.removeAll(keepingCapacity: true)
        guard !batch.isEmpty else { return }
        // Placeholder — real implementation lands in Task 2.3.
    }
}
