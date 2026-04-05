import SwiftUI
import CoreImage.CIFilterBuiltins
import Network

struct NetworkAddress {
    let ip: String
    let type: AddressType

    enum AddressType: String {
        case tailscale  // utun interfaces with 100.x.x.x (CGNAT range)
        case wifi       // en0/en1 interfaces with private IPs
    }
}

struct ConnectionQRView: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    @Environment(\.dismiss) private var dismiss

    @State private var addresses: [NetworkAddress] = []
    @State private var relayCode: String?
    @State private var isCreatingRelay = false
    @State private var relayError: String?
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "qrcode")
                        .font(.system(size: 40))
                        .foregroundStyle(.blue)

                    Text("Scan to Connect")
                        .font(.title2.bold())

                    if let deepLink = smartDeepLink {
                        if let qrImage = generateQRCode(from: deepLink) {
                            Image(uiImage: qrImage)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 220, height: 220)
                                .cornerRadius(8)
                        }

                        // Connection methods status
                        VStack(alignment: .leading, spacing: 8) {
                            if let ts = addresses.first(where: { $0.type == .tailscale }) {
                                Label("Tailscale: \(ts.ip)", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                            if let wifi = addresses.first(where: { $0.type == .wifi }) {
                                Label("WiFi: \(wifi.ip)", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                            if let code = relayCode {
                                Label("Relay: \(code)", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else if isCreatingRelay {
                                Label("Relay: \(String(localized: "建立中..."))", systemImage: "arrow.triangle.2.circlepath")
                                    .foregroundStyle(.orange)
                            } else if let error = relayError {
                                Label("Relay: \(error)", systemImage: "xmark.circle.fill")
                                    .foregroundStyle(.red)
                            }

                            if addresses.isEmpty && relayCode == nil && !isCreatingRelay {
                                Label(String(localized: "未偵測到網路連線"), systemImage: "wifi.slash")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.caption)
                        .padding(.horizontal)

                        Text(deepLink)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                            .padding(.horizontal)

                        Button {
                            UIPasteboard.general.string = deepLink
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                copied = false
                            }
                        } label: {
                            Label(copied ? String(localized: "已複製") : String(localized: "Copy Link"), systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                    } else if addresses.isEmpty && relayCode == nil && !isCreatingRelay {
                        Text("Unable to determine local address.\nMake sure you are connected to a network.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    } else {
                        ProgressView()
                            .padding()
                    }
                }
                .padding()
            }
            .navigationTitle("My QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            addresses = Self.availableAddresses()
            await createRelayRoom()
        }
    }

    // MARK: - Smart Deep Link

    /// Build a `peerdrop://smart?ts=IP:PORT&local=IP:PORT&relay=CODE&name=NAME` URL.
    private var smartDeepLink: String? {
        let port = connectionManager.localListenerPort
        let name = connectionManager.localIdentity.displayName
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? connectionManager.localIdentity.displayName

        var params: [String] = []

        if let port {
            if let ts = addresses.first(where: { $0.type == .tailscale }) {
                params.append("ts=\(ts.ip):\(port)")
            }
            if let wifi = addresses.first(where: { $0.type == .wifi }) {
                params.append("local=\(wifi.ip):\(port)")
            }
        }
        if let code = relayCode {
            params.append("relay=\(code)")
        }
        params.append("name=\(name)")

        // Need at least one connection method besides name
        guard params.count >= 2 else {
            // If only name param, nothing useful
            return params.count == 1 ? nil : nil
        }

        return "peerdrop://smart?\(params.joined(separator: "&"))"
    }

    // MARK: - Relay Room

    private func createRelayRoom() async {
        isCreatingRelay = true
        do {
            let signaling = WorkerSignaling()
            let room = try await signaling.createRoom()
            relayCode = room.roomCode
        } catch {
            relayError = error.localizedDescription
        }
        isCreatingRelay = false
    }

    // MARK: - QR Code Generation

    private func generateQRCode(from string: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }
        let scale = 10.0
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    // MARK: - Network Detection

    /// Returns all available network addresses, prioritized: Tailscale first, then WiFi.
    static func availableAddresses() -> [NetworkAddress] {
        var addresses: [NetworkAddress] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            guard addrFamily == UInt8(AF_INET) else { continue }

            let name = String(cString: interface.ifa_name)
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                        &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
            let ip = String(cString: hostname)

            // Tailscale uses utun interfaces with CGNAT range 100.64.0.0/10
            if name.hasPrefix("utun"), ip.hasPrefix("100.") {
                addresses.append(NetworkAddress(ip: ip, type: .tailscale))
            }
            // WiFi
            else if name == "en0" || name == "en1" {
                addresses.append(NetworkAddress(ip: ip, type: .wifi))
            }
        }

        // Sort: tailscale first
        return addresses.sorted { $0.type == .tailscale && $1.type != .tailscale }
    }

    /// Legacy helper — returns the first WiFi address (for backward compatibility).
    static func localIPAddress() -> String? {
        availableAddresses().first(where: { $0.type == .wifi })?.ip
    }
}
