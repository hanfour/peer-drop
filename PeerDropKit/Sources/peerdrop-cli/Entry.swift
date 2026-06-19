import Foundation
import Combine
import PeerDropCore
import PeerDropSecurity

@main
struct PeerDropCLISpike {
    static func main() {
        // Run setup synchronously. main() is called on the main thread by
        // Swift's @main machinery, so assumeIsolated is safe here.
        // dispatchMain() is the correct run-forever primitive for headless
        // CLI tools: it hands control to libdispatch's main queue so
        // NWBrowser/NWListener callbacks (queued on the main queue) fire.
        MainActor.assumeIsolated { run() }
        dispatchMain()
    }

    @MainActor
    static func run() {
        let name = "peerdrop-cli spike"
        UserDefaults.standard.set(name, forKey: "peerDropDisplayName")
        HeadlessPlatform.register(deviceName: name)

        let cm = ConnectionManager()
        var bag = Set<AnyCancellable>()

        print("peerdrop-cli ready · fingerprint \(IdentityKeyManager.shared.fingerprint)")
        print("advertising as \"\(name)\" — waiting for a connection…")

        cm.$pendingIncomingRequest
            .compactMap { $0 }
            .sink { req in
                print("incoming connection from \(req.peerIdentity.displayName) — accepting")
                cm.acceptConnection()
            }
            .store(in: &bag)

        cm.$pendingLocalFirstTrust
            .compactMap { $0 }
            .sink { pending in
                print("SAS for \(pending.senderDisplayName): \(pending.sas ?? "n/a") — auto-approving (spike)")
                cm.approveLocalFirstTrust(fingerprint: pending.fingerprint)
            }
            .store(in: &bag)

        cm.startDiscovery()

        Self.retained = (cm, bag)
    }

    @MainActor static var retained: (ConnectionManager, Set<AnyCancellable>)?
}
