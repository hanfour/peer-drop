#if canImport(WebRTC)
import Foundation
import PeerDropTransport
import PeerDropSecurity
@preconcurrency import WebRTC

// Project E — production `RendezvousNegotiator`: one WebRTC data channel via
// `DataChannelClient` / `DataChannelTransport`, configured like `RelaySession`
// but with `iceTransportPolicy = .all` always (no relay-only hint) and ICE
// servers from the anonymous `POST /rv/ice`. Remote ICE candidates are queued
// until the remote description is set; local ICE candidates are queued until
// our own SDP has been handed to signaling (an offer must precede its ICE on
// the ordered signaling channel). Nothing is logged (SDP/ICE carry IPs).

@MainActor
public final class WebRTCRendezvousNegotiator: RendezvousNegotiator {
    public var onLocalSignal: ((RendezvousSignal) -> Void)?
    public var onOpen: ((TransportProtocol) -> Void)?
    public var onClosed: (() -> Void)?

    private let role: RendezvousRole
    private let configuration: RTCConfiguration
    private var client: DataChannelClient?
    private var transport: DataChannelTransport?
    /// A remote description was received (one per negotiation).
    private var remoteDescriptionSet = false
    /// `setRemoteSDP` has completed: only now may ICE candidates be added.
    private var remoteDescriptionApplied = false
    /// Peer ICE candidates accepted (queued + added), capped.
    private var remoteICECount = 0
    static let maxRemoteICECandidates = RendezvousSession.maxRemoteICECandidates
    private var localDescriptionSent = false
    var pendingRemoteICECountForTesting: Int { pendingRemoteICE.count }
    private var pendingRemoteICE: [RendezvousSignal] = []
    private var pendingLocalICE: [RendezvousSignal] = []
    private var opened = false
    private var finished = false

    public init(role: RendezvousRole, iceServers: [RendezvousICEServer]) {
        self.role = role
        self.configuration = Self.configuration(iceServers: iceServers)
    }

    /// `.all` policy; STUN defaults when the Worker returned nothing.
    static func configuration(iceServers: [RendezvousICEServer]) -> RTCConfiguration {
        let config = ICEConfigurationProvider.defaultConfiguration()
        if !iceServers.isEmpty {
            config.iceServers = iceServers.map {
                RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential)
            }
        }
        config.iceTransportPolicy = .all
        return config
    }

    public func start() {
        guard client == nil, !finished else { return }
        let client = DataChannelClient()
        self.client = client
        client.setup(with: configuration)
        let transport = DataChannelTransport(client: client)
        self.transport = transport
        transport.onStateChange = { [weak self] state in
            Task { @MainActor in self?.transportStateChanged(state) }
        }
        client.onICECandidate = { [weak self] candidate in
            let signal = RendezvousSignal.ice(sdp: candidate.sdp, mid: candidate.sdpMid, index: candidate.sdpMLineIndex)
            Task { @MainActor in self?.localICE(signal) }
        }
        guard role == .offerer else { return }
        guard client.createDataChannel() != nil else { fail(); return }
        Task { [weak self] in
            do {
                let offer = try await client.createOffer()
                self?.emitLocalDescription(.offer(sdp: offer.sdp))
            } catch {
                self?.fail()
            }
        }
    }

    public func handleRemote(_ signal: RendezvousSignal) {
        guard let client, !finished else { return }
        switch (signal, role) {
        case (.offer(let sdp), .answerer):
            guard !remoteDescriptionSet else { return }
            remoteDescriptionSet = true
            Task { [weak self] in
                do {
                    try await client.setRemoteSDP(RTCSessionDescription(type: .offer, sdp: sdp))
                    self?.remoteDescriptionDidApply()
                    let answer = try await client.createAnswer()
                    self?.emitLocalDescription(.answer(sdp: answer.sdp))
                } catch {
                    self?.fail()
                }
            }
        case (.answer(let sdp), .offerer):
            guard !remoteDescriptionSet else { return }
            remoteDescriptionSet = true
            Task { [weak self] in
                do {
                    try await client.setRemoteSDP(RTCSessionDescription(type: .answer, sdp: sdp))
                    self?.remoteDescriptionDidApply()
                } catch {
                    self?.fail()
                }
            }
        case (.ice, _):
            guard remoteICECount < Self.maxRemoteICECandidates else { return }
            remoteICECount += 1
            if remoteDescriptionApplied { addRemoteICE(signal) } else { pendingRemoteICE.append(signal) }
        default:
            return
        }
    }

    public func close() {
        guard !finished else { return }
        finished = true
        onLocalSignal = nil
        onOpen = nil
        onClosed = nil
        transport?.onStateChange = nil
        client?.onICECandidate = nil
        transport?.close()
        client?.close()
        transport = nil
        client = nil
    }

    // MARK: Private

    private func emitLocalDescription(_ signal: RendezvousSignal) {
        guard !finished else { return }
        onLocalSignal?(signal)
        localDescriptionSent = true
        let queued = pendingLocalICE
        pendingLocalICE = []
        queued.forEach { onLocalSignal?($0) }
    }

    private func localICE(_ signal: RendezvousSignal) {
        guard !finished else { return }
        if localDescriptionSent { onLocalSignal?(signal) } else if pendingLocalICE.count < 64 { pendingLocalICE.append(signal) }
    }

    private func remoteDescriptionDidApply() {
        guard !finished else { return }
        remoteDescriptionApplied = true
        let queued = pendingRemoteICE
        pendingRemoteICE = []
        queued.forEach(addRemoteICE)
    }

    private func addRemoteICE(_ signal: RendezvousSignal) {
        guard case .ice(let sdp, let mid, let index) = signal, let client else { return }
        let candidate = RTCIceCandidate(sdp: sdp, sdpMLineIndex: index, sdpMid: mid)
        Task { try? await client.addICECandidate(candidate) }
    }

    private func transportStateChanged(_ state: TransportState) {
        guard !finished else { return }
        switch state {
        case .ready:
            guard !opened, let transport else { return }
            opened = true
            onOpen?(transport)
        case .failed, .cancelled:
            fail()
        case .connecting:
            break
        }
    }

    private func fail() {
        guard !finished else { return }
        let cb = onClosed
        close()
        cb?()
    }
}

extension RendezvousManager {
    /// Production wiring: ONE session-tag store shared by the manager (which
    /// forgets expired days' tags) and the signaling factory (which uses them).
    public static func live(
        contacts: @escaping () -> [TrustedContact],
        secrets: RendezvousSecretProvider = IdentityRendezvousSecretProvider(),
        direct: DirectConnectionChecker,
        installer: RendezvousConnectionInstaller,
        baseURL: URL = WorkerURL.current(),
        sessionTags: RendezvousSessionTagStore = .process
    ) -> RendezvousManager {
        RendezvousManager(
            contacts: contacts, secrets: secrets, direct: direct, installer: installer,
            signaling: LiveRendezvousSignalingFactory(provider: secrets, baseURL: baseURL, sessionTags: sessionTags),
            negotiators: WebRTCRendezvousNegotiatorFactory(),
            sessionTags: sessionTags)
    }
}

@MainActor
public final class WebRTCRendezvousNegotiatorFactory: RendezvousNegotiatorFactory {
    public init() {}
    public func makeNegotiator(role: RendezvousRole, iceServers: [RendezvousICEServer]) -> RendezvousNegotiator {
        WebRTCRendezvousNegotiator(role: role, iceServers: iceServers)
    }
}
#endif
