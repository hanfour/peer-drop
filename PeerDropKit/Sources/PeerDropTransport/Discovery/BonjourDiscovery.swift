import Foundation
import Network
import Combine
import os

private let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "BonjourDiscovery")

public final class BonjourDiscovery: DiscoveryBackend {
    private static let serviceType = "_peerdrop._tcp"
    private static let serviceDomain = "local"

    public let source: DiscoverySource = .bonjour

    private let peersSubject = CurrentValueSubject<[DiscoveredPeer], Never>([])
    public var peersPublisher: AnyPublisher<[DiscoveredPeer], Never> {
        peersSubject.eraseToAnyPublisher()
    }

    private var browser: NWBrowser?
    private var listener: NWListener?
    private let listenerPort: NWEndpoint.Port
    private let localPeerName: String
    /// Identity UUID published in the service TXT record ("pid") so the
    /// browsing side can key `DiscoveredPeer.id` to the SAME namespace as
    /// `ConnectionManager.connections` (audit round 15 — without this the
    /// two ID spaces never matched and every `connection(for:)` lookup
    /// from a DiscoveredPeer missed). nil → no TXT, legacy behavior.
    private let localPeerID: String?
    private let tlsOptions: NWProtocolTLS.Options?
    private let queue = DispatchQueue(label: "com.peerdrop.bonjour")
    private var isRestartingListener = false
    private var isRestartingBrowser = false

    public init(
        port: UInt16 = 0,
        localPeerName: String,
        localPeerID: String? = nil,
        tlsOptions: NWProtocolTLS.Options? = nil
    ) {
        self.listenerPort = port == 0 ? .any : NWEndpoint.Port(rawValue: port)!
        self.localPeerName = localPeerName
        self.localPeerID = localPeerID
        self.tlsOptions = tlsOptions
    }

    /// Resolve a browse result to a stable peer ID: prefer the identity
    /// UUID from the TXT record ("pid"); fall back to the legacy
    /// "name.type.domain" service string for pre-v6 peers without TXT.
    /// Pure function — unit-tested in BonjourPeerIDTests.
    static func resolvedPeerID(
        name: String,
        type: String,
        domain: String,
        metadata: NWBrowser.Result.Metadata?
    ) -> String {
        if case .bonjour(let txt) = metadata,
           let pid = txt["pid"], !pid.isEmpty {
            return pid
        }
        return "\(name).\(type).\(domain)"
    }

    public var actualPort: UInt16? {
        listener?.port?.rawValue
    }

    public func startDiscovery() {
        startAdvertising()
        startBrowsing()
    }

    public func stopDiscovery() {
        browser?.cancel()
        browser = nil
        listener?.cancel()
        listener = nil
        peersSubject.send([])
    }

    // MARK: - Advertising

    private func startAdvertising() {
        do {
            let params = NWParameters.peerDrop(tls: tlsOptions)
            params.includePeerToPeer = true

            let listener = try NWListener(using: params, on: listenerPort)
            if let localPeerID {
                var txt = NWTXTRecord()
                txt["pid"] = localPeerID
                listener.service = NWListener.Service(
                    name: localPeerName,
                    type: Self.serviceType,
                    domain: Self.serviceDomain,
                    txtRecord: txt.data
                )
            } else {
                listener.service = NWListener.Service(
                    name: localPeerName,
                    type: Self.serviceType,
                    domain: Self.serviceDomain
                )
            }

            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    logger.info("Listener ready on port: \(listener.port?.rawValue ?? 0)")
                case .failed(let error):
                    logger.error("Listener failed: \(error.localizedDescription), restarting...")
                    listener.cancel()
                    self?.listener = nil
                    guard self?.isRestartingListener != true else { return }
                    self?.isRestartingListener = true
                    self?.queue.asyncAfter(deadline: .now() + 2.0) {
                        self?.isRestartingListener = false
                        self?.startAdvertising()
                    }
                case .cancelled:
                    break
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.handleIncomingConnection(connection)
            }

            listener.start(queue: queue)
            self.listener = listener
        } catch {
            logger.error("Failed to create listener: \(error.localizedDescription)")
        }
    }

    /// Callback for incoming connections — forwarded to ConnectionManager.
    public var onIncomingConnection: ((NWConnection) -> Void)?

    private func handleIncomingConnection(_ connection: NWConnection) {
        logger.info("New incoming connection: \(String(describing: connection.endpoint))")
        onIncomingConnection?(connection)
    }

    // MARK: - Browsing

    private func startBrowsing() {
        // bonjourWithTXTRecord delivers each result's TXT metadata so
        // resolvedPeerID can prefer the advertised identity UUID ("pid").
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
            type: Self.serviceType,
            domain: Self.serviceDomain
        )
        let params = NWParameters()
        params.includePeerToPeer = true

        let browser = NWBrowser(for: descriptor, using: params)
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                break
            case .failed(let error):
                logger.error("Browser failed: \(error.localizedDescription), restarting...")
                browser.cancel()
                self?.browser = nil
                guard self?.isRestartingBrowser != true else { return }
                self?.isRestartingBrowser = true
                self?.queue.asyncAfter(deadline: .now() + 2.0) {
                    self?.isRestartingBrowser = false
                    self?.startBrowsing()
                }
            case .cancelled:
                break
            default:
                break
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.handleBrowseResults(results)
        }

        browser.start(queue: queue)
        self.browser = browser
    }

    /// Returns `true` if `name` matches our local peer name or a Bonjour-renamed
    /// variant like "Name (2)", "Name (3)", etc.
    private func isSelfByName(_ name: String) -> Bool {
        if name == localPeerName { return true }
        // Bonjour auto-renames colliding services by appending " (N)"
        guard name.hasPrefix(localPeerName + " ("),
              name.hasSuffix(")") else { return false }
        let start = name.index(name.startIndex, offsetBy: localPeerName.count + 2)
        let end = name.index(before: name.endIndex)
        let digits = name[start..<end]
        return !digits.isEmpty && digits.allSatisfy(\.isNumber)
    }

    /// Returns `true` if the interface is a loopback interface.
    private func isLocalInterface(_ interface: NWInterface) -> Bool {
        interface.type == .loopback
    }

    /// Returns `true` if the browse result represents this device.
    private func isSelf(_ result: NWBrowser.Result) -> Bool {
        guard case .service(let name, _, _, let interface) = result.endpoint else {
            return false
        }

        // 0. TXT pid match — exact and rename-proof (audit round 15).
        if let localPeerID,
           case .bonjour(let txt) = result.metadata,
           let pid = txt["pid"], pid == localPeerID {
            return true
        }

        // 1. Name-based detection (including Bonjour-renamed variants)
        if isSelfByName(name) { return true }

        // 2. Interface-based detection - check if it's a loopback interface
        if let interface = interface, isLocalInterface(interface) {
            return true
        }

        return false
    }

    private func handleBrowseResults(_ results: Set<NWBrowser.Result>) {
        logger.info("browseResultsChanged: \(results.count) results")
        let peers = results.compactMap { result -> DiscoveredPeer? in
            guard case .service(let name, let type, let domain, _) = result.endpoint else {
                return nil
            }
            // Skip self (including Bonjour-renamed variants and loopback interfaces)
            guard !isSelf(result) else { return nil }

            return DiscoveredPeer(
                id: Self.resolvedPeerID(name: name, type: type, domain: domain, metadata: result.metadata),
                displayName: name,
                endpoint: .bonjour(name: name, type: type, domain: domain),
                source: .bonjour
            )
        }
        logger.info("Publishing \(peers.count) peers: \(peers.map { $0.displayName })")
        peersSubject.send(peers)
    }
}
