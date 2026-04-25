import Foundation
@preconcurrency import WebRTC
import os

/// Owns the full lifecycle of one relay connection attempt. This is a
/// **structural** safety wrapper: the deinit guarantees that the signaling
/// WebSocket is closed if the session ends in any state other than .connected,
/// so callers cannot leak zombie sockets onto the Worker DO (the v3.3.0 bug).
///
/// Lifecycle:
///   1. init — wire up dependencies (signaling, metrics token, ICE config)
///   2. start() — kick off creator or joiner flow
///   3. EITHER onConnected fires (success) OR session goes out of scope without
///      connecting (deinit closes signaling). There is no "session ended in
///      failure but signaling left open" state.
final class RelaySession {

    enum Role {
        case creator                          // we send the offer
        case joiner                           // we send the answer
    }

    enum Outcome {
        case pending                           // no terminal state yet
        case connected(DataChannelTransport)   // success — caller will use the transport
        case failed(reason: String)            // explicit failure path
        case cancelled                         // ConnectionManager cancelled us
    }

    // MARK: - Inputs (immutable after init)

    private let roomCode: String
    private let role: Role
    private let signaling: WorkerSignalingProtocol
    private let metricsToken: ConnectionMetrics.Token
    private let iceResult: WorkerSignaling.ICEResult?
    private let logger: Logger

    // MARK: - State

    private var outcome: Outcome = .pending
    private var client: DataChannelClient?
    private var transport: DataChannelTransport?
    private var phase1Task: Task<Void, Never>?
    private var phase3Task: Task<Void, Never>?
    private var ourIceOrder: Int = 0

    // MARK: - Outputs (set by ConnectionManager before calling start)

    var onConnected: ((DataChannelTransport) -> Void)?
    var onFailed: ((String) -> Void)?

    // MARK: - Init

    init(
        roomCode: String,
        role: Role,
        signaling: WorkerSignalingProtocol,
        metricsToken: ConnectionMetrics.Token,
        iceResult: WorkerSignaling.ICEResult?,
        logger: Logger
    ) {
        self.roomCode = roomCode
        self.role = role
        self.signaling = signaling
        self.metricsToken = metricsToken
        self.iceResult = iceResult
        self.logger = logger
    }

    // MARK: - Critical invariant

    deinit {
        // CRITICAL: this is the v3.3.0 zombie-socket fix made structural.
        // If we end in any state other than .connected, the signaling WS
        // MUST be closed so the Worker DO evicts our socket instead of
        // keeping a zombie that fills the room.
        //
        // deinit is nonisolated; we cannot await. The signaling reference
        // is captured by value (it's a class), and WorkerSignaling.disconnect()
        // is safe to call from any thread (the underlying URLSessionWebSocketTask.cancel
        // is documented thread-safe). Calling synchronously here keeps the test
        // assertion deterministic and avoids the Task-hop race.
        if case .connected = outcome { return }
        signaling.disconnect()
        // Cancel timers so they don't outlive us.
        phase1Task?.cancel()
        phase3Task?.cancel()
    }

    // MARK: - Public API

    /// Start the relay flow. Returns when initial setup is dispatched; outcome is
    /// delivered via onConnected / onFailed callbacks.
    @MainActor
    func start() async {
        switch role {
        case .creator: await startCreator()
        case .joiner:  startJoiner()
        }
    }

    /// Caller (ConnectionManager) signals it no longer wants this session.
    /// Idempotent; transitions outcome to .cancelled if still .pending.
    @MainActor
    func cancel(reason: String = "superseded") {
        guard case .pending = outcome else { return }
        outcome = .cancelled
        phase1Task?.cancel(); phase1Task = nil
        phase3Task?.cancel(); phase3Task = nil
        signaling.disconnect()
        client?.close()
    }

    // MARK: - Internal — terminal transitions

    @MainActor
    private func recordSuccess(_ transport: DataChannelTransport) async {
        guard case .pending = outcome else { return }
        outcome = .connected(transport)
        phase1Task?.cancel(); phase3Task?.cancel()
        signaling.disconnect()
        await ConnectionMetrics.shared.recordConnected(metricsToken, used: .relay)
        onConnected?(transport)
    }

    @MainActor
    private func recordFailure(_ reason: String, context: String, extras: [String: String] = [:]) async {
        guard case .pending = outcome else { return }
        outcome = .failed(reason: reason)
        phase1Task?.cancel(); phase3Task?.cancel()
        var allExtras = extras
        allExtras["roomCode"] = roomCode
        ErrorReporter.report(error: reason, context: context, extras: allExtras)
        await ConnectionMetrics.shared.recordFailure(metricsToken, reason: reason)
        signaling.disconnect()
        onFailed?(reason)
    }

    // MARK: - Joiner flow

    @MainActor
    private func startJoiner() {
        let client = DataChannelClient()
        self.client = client

        let fingerprint = Self.currentNetworkFingerprint()
        let preferRelay = RelayHintsStore.shared.shouldPreferRelay(fingerprint: fingerprint)
        let config: RTCConfiguration
        if let creds = iceResult?.credentials {
            config = ICEConfigurationProvider.configuration(with: creds)
        } else {
            config = ICEConfigurationProvider.defaultConfiguration()
        }
        if preferRelay {
            config.iceTransportPolicy = .relay
            logger.info("RelaySession: preferring relay for fingerprint \(fingerprint)")
        }
        client.setup(with: config)
        // Joiner doesn't create data channel — it receives one from the offerer

        let handshakeStart = Date()
        // Phase mirrors the legacy completeJoinerHandshake flow:
        //   1 = direct connection window (0–8s)
        //   2 = accept relay (8–30s)
        //   3 = give up
        let phase1DeadlineNs: UInt64 = 8_000_000_000
        let phase3TimeoutNs: UInt64 = 30_000_000_000

        // Use a class wrapper so the closures can mutate `phase` without
        // borrowing self into the captures.
        final class PhaseBox { var value: Int = 1 }
        let phaseBox = PhaseBox()

        // SDP offer
        signaling.onSDPOffer = { [weak self] sdp in
            guard let self else { return }
            Task { @MainActor in
                guard case .pending = self.outcome else { return }
                do {
                    try await client.setRemoteSDP(RTCSessionDescription(type: .offer, sdp: sdp))
                    let answer = try await client.createAnswer()
                    self.signaling.sendSDP(answer.sdp, type: "answer")
                } catch {
                    await self.recordFailure(
                        "sdpOffer: \(error.localizedDescription)",
                        context: "relay.joiner.sdpOffer",
                        extras: ["step": "handleOffer"]
                    )
                }
            }
        }

        // ICE candidates: outbound
        client.onICECandidate = { [weak self] candidate in
            guard let self else { return }
            // Send via signaling on the actor we know about (MainActor) so no
            // reentrancy weirdness; signaling.sendICECandidate is itself thread-safe.
            self.signaling.sendICECandidate(
                sdp: candidate.sdp, sdpMid: candidate.sdpMid, sdpMLineIndex: candidate.sdpMLineIndex
            )
            Task { @MainActor in
                self.ourIceOrder += 1
                let order = self.ourIceOrder
                let candType = Self.parseCandidateType(from: candidate.sdp)
                let isV6 = Self.isIPv6Candidate(sdp: candidate.sdp)
                await ConnectionMetrics.shared.recordICEGather(
                    self.metricsToken, candidate: candType, order: order, isIPv6: isV6
                )
            }
        }

        // ICE candidates: inbound
        signaling.onICECandidate = { sdp, sdpMid, sdpMLineIndex in
            Task {
                let cand = RTCIceCandidate(sdp: sdp, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
                try? await client.addICECandidate(cand)
            }
        }

        // Signaling errors
        signaling.onError = { [weak self] error in
            guard let self else { return }
            let nsErr = error as NSError
            Task { @MainActor in
                await self.recordFailure(
                    "webSocket: \(nsErr.localizedDescription)",
                    context: "relay.joiner.webSocket",
                    extras: ["errorDomain": nsErr.domain, "errorCode": "\(nsErr.code)", "step": "webSocketSignaling"]
                )
            }
        }

        // DataChannel state
        let transport = DataChannelTransport(client: client)
        self.transport = transport
        transport.onStateChange = { [weak self] state in
            guard let self else { return }
            Task { @MainActor in
                guard case .pending = self.outcome else { return }
                switch state {
                case .ready:
                    let elapsedMs = Int(Date().timeIntervalSince(handshakeStart) * 1000)
                    await ConnectionMetrics.shared.recordPhaseTime(
                        self.metricsToken, phase: phaseBox.value, elapsedMs: elapsedMs
                    )
                    if phaseBox.value == 1 {
                        RelayHintsStore.shared.recordPhase1Success(fingerprint: fingerprint)
                    } else {
                        RelayHintsStore.shared.recordPhase2Save(fingerprint: fingerprint)
                    }
                    await self.recordSuccess(transport)
                case .failed(let err):
                    await self.recordFailure(
                        "dataChannel: \(err.localizedDescription)",
                        context: "relay.joiner.dataChannel",
                        extras: ["step": "dataChannelTransport"]
                    )
                case .cancelled, .connecting:
                    break
                }
            }
        }

        // Phase 1 → 2 at 8s
        phase1Task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: phase1DeadlineNs)
            guard let self else { return }
            await MainActor.run {
                guard case .pending = self.outcome else { return }
                phaseBox.value = 2
                self.logger.info("RelaySession: joiner phase 1 → 2 (direct not yet succeeded)")
            }
        }

        // Phase 3 timeout at 30s
        phase3Task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: phase3TimeoutNs)
            guard let self else { return }
            await MainActor.run {
                guard case .pending = self.outcome else { return }
                Task { @MainActor in
                    await self.recordFailure(
                        "phase3Timeout",
                        context: "relay.joiner.timeout",
                        extras: ["step": "phase3Timeout"]
                    )
                }
            }
        }
    }

    // MARK: - Creator flow

    @MainActor
    private func startCreator() async {
        let client = DataChannelClient()
        self.client = client

        let creatorConfig: RTCConfiguration
        if let creds = iceResult?.credentials {
            creatorConfig = ICEConfigurationProvider.configuration(with: creds)
        } else {
            creatorConfig = ICEConfigurationProvider.defaultConfiguration()
        }
        client.setup(with: creatorConfig)
        guard client.createDataChannel() != nil else {
            await recordFailure(
                "creatorSetup: createDataChannel returned nil",
                context: "relay.creator.setup",
                extras: ["step": "creatorSetup"]
            )
            return
        }

        let offer: RTCSessionDescription
        do {
            offer = try await client.createOffer()
        } catch {
            await recordFailure(
                "creatorSetup: \(error.localizedDescription)",
                context: "relay.creator.setup",
                extras: [
                    "errorDomain": (error as NSError).domain,
                    "errorCode": "\((error as NSError).code)",
                    "step": "creatorSetup",
                ]
            )
            return
        }

        // ICE candidates: outbound
        client.onICECandidate = { [weak self] candidate in
            guard let self else { return }
            self.signaling.sendICECandidate(sdp: candidate.sdp, sdpMid: candidate.sdpMid, sdpMLineIndex: candidate.sdpMLineIndex)
            Task { @MainActor in
                self.ourIceOrder += 1
                let order = self.ourIceOrder
                let candType = Self.parseCandidateType(from: candidate.sdp)
                let isV6 = Self.isIPv6Candidate(sdp: candidate.sdp)
                await ConnectionMetrics.shared.recordICEGather(
                    self.metricsToken, candidate: candType, order: order, isIPv6: isV6
                )
            }
        }

        // ICE candidates: inbound
        signaling.onICECandidate = { sdp, sdpMid, sdpMLineIndex in
            Task {
                let cand = RTCIceCandidate(sdp: sdp, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
                try? await client.addICECandidate(cand)
            }
        }

        // Send offer when peer joins. The legacy code used an AsyncStream so the
        // event was buffered if the joiner connected before the offer was ready;
        // here createOffer has already returned by the time we install this hook,
        // so a direct callback is sufficient.
        signaling.onPeerJoined = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                guard case .pending = self.outcome else { return }
                self.signaling.sendSDP(offer.sdp, type: "offer")
            }
        }

        // SDP answer
        signaling.onSDPAnswer = { [weak self] sdp in
            guard let self else { return }
            Task { @MainActor in
                guard case .pending = self.outcome else { return }
                do {
                    try await client.setRemoteSDP(RTCSessionDescription(type: .answer, sdp: sdp))
                } catch {
                    await self.recordFailure(
                        "sdpAnswer: \(error.localizedDescription)",
                        context: "relay.creator.sdpAnswer",
                        extras: ["step": "setRemoteSDP"]
                    )
                }
            }
        }

        // Signaling errors
        signaling.onError = { [weak self] error in
            guard let self else { return }
            let nsErr = error as NSError
            Task { @MainActor in
                await self.recordFailure(
                    "webSocket: \(nsErr.localizedDescription)",
                    context: "relay.creator.webSocket",
                    extras: ["errorDomain": nsErr.domain, "errorCode": "\(nsErr.code)", "step": "webSocketSignaling"]
                )
            }
        }

        // DataChannel state
        let transport = DataChannelTransport(client: client)
        self.transport = transport
        transport.onStateChange = { [weak self] state in
            guard let self else { return }
            Task { @MainActor in
                guard case .pending = self.outcome else { return }
                switch state {
                case .ready:
                    await self.recordSuccess(transport)
                case .failed(let err):
                    await self.recordFailure(
                        "dataChannel: \(err.localizedDescription)",
                        context: "relay.creator.dataChannel",
                        extras: ["step": "dataChannelTransport"]
                    )
                case .cancelled, .connecting:
                    break
                }
            }
        }

        // 30s negotiation timeout
        phase3Task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard let self else { return }
            await MainActor.run {
                guard case .pending = self.outcome else { return }
                Task { @MainActor in
                    await self.recordFailure(
                        "negotiationTimeout",
                        context: "relay.creator.timeout",
                        extras: ["step": "negotiationTimeout"]
                    )
                }
            }
        }
    }

    // MARK: - Helpers (moved from ConnectionManager)

    /// Returns a stable fingerprint for the current network based on en0/en1/bridge subnet.
    /// Mirrors the helper that previously lived in ConnectionManager.
    fileprivate static func currentNetworkFingerprint() -> String {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return "unknown" }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let i = ptr.pointee
            let name = String(cString: i.ifa_name)
            guard let addr = i.ifa_addr else { continue }
            guard name == "en0" || name == "en1" || name.hasPrefix("bridge"),
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                        &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: host)
            let octets = ip.split(separator: ".")
            guard octets.count == 4 else { continue }
            let subnet = "\(octets[0]).\(octets[1]).\(octets[2]).0/24"
            let gateway = "\(octets[0]).\(octets[1]).\(octets[2]).1"
            return NetworkFingerprint.fingerprint(subnet: subnet, gateway: gateway)
        }
        return "unknown"
    }

    fileprivate static func parseCandidateType(from sdp: String) -> ConnectionMetric.CandidateType {
        if sdp.contains("typ host") { return .host }
        if sdp.contains("typ srflx") { return .srflx }
        if sdp.contains("typ relay") { return .relay }
        return .prflx
    }

    fileprivate static func isIPv6Candidate(sdp: String) -> Bool {
        if sdp.contains("::") { return true }
        let tokens = sdp.components(separatedBy: " ").dropFirst()
        return tokens.contains { $0.contains(":") && !$0.contains(".") && $0.count >= 3 }
    }
}
