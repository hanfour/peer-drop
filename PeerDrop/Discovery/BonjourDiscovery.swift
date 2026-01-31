import Foundation
import Network
import Combine

final class BonjourDiscovery: DiscoveryBackend {
    private static let serviceType = "_peerdrop._tcp"
    private static let serviceDomain = "local"

    private let peersSubject = CurrentValueSubject<[DiscoveredPeer], Never>([])
    var peersPublisher: AnyPublisher<[DiscoveredPeer], Never> {
        peersSubject.eraseToAnyPublisher()
    }

    private var browser: NWBrowser?
    private var listener: NWListener?
    private let listenerPort: NWEndpoint.Port
    private let localPeerName: String
    private let tlsOptions: NWProtocolTLS.Options?
    private let queue = DispatchQueue(label: "com.peerdrop.bonjour")

    init(port: UInt16 = 0, localPeerName: String, tlsOptions: NWProtocolTLS.Options? = nil) {
        self.listenerPort = port == 0 ? .any : NWEndpoint.Port(rawValue: port)!
        self.localPeerName = localPeerName
        self.tlsOptions = tlsOptions
    }

    var actualPort: UInt16? {
        listener?.port?.rawValue
    }

    func startDiscovery() {
        startAdvertising()
        startBrowsing()
    }

    func stopDiscovery() {
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
            listener.service = NWListener.Service(
                name: localPeerName,
                type: Self.serviceType,
                domain: Self.serviceDomain
            )

            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    break
                case .failed(let error):
                    print("[BonjourDiscovery] Listener failed: \(error), restarting...")
                    listener.cancel()
                    // Restart after brief delay
                    self?.queue.asyncAfter(deadline: .now() + 2.0) {
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
            print("[BonjourDiscovery] Failed to create listener: \(error)")
        }
    }

    /// Callback for incoming connections — forwarded to ConnectionManager.
    var onIncomingConnection: ((NWConnection) -> Void)?

    private func handleIncomingConnection(_ connection: NWConnection) {
        onIncomingConnection?(connection)
    }

    // MARK: - Browsing

    private func startBrowsing() {
        let descriptor = NWBrowser.Descriptor.bonjour(
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
                print("[BonjourDiscovery] Browser failed: \(error), restarting...")
                browser.cancel()
                self?.queue.asyncAfter(deadline: .now() + 2.0) {
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

    private func handleBrowseResults(_ results: Set<NWBrowser.Result>) {
        let peers = results.compactMap { result -> DiscoveredPeer? in
            guard case .service(let name, let type, let domain, _) = result.endpoint else {
                return nil
            }
            // Skip self
            guard name != localPeerName else { return nil }

            return DiscoveredPeer(
                id: "\(name).\(type).\(domain)",
                displayName: name,
                endpoint: .bonjour(name: name, type: type, domain: domain),
                source: .bonjour
            )
        }
        peersSubject.send(peers)
    }
}
