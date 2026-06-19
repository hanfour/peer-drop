import Foundation
import Darwin
import Combine
import PeerDropCore
import PeerDropSecurity

@main
struct PeerDropCLI {
    // Strong references kept alive for the duration of the process.
    @MainActor static var retained: Any?

    static func main() {
        // Unbuffer stdout so banner/log lines flush immediately.
        // print() is block-buffered when stdout is a pipe, which would hide
        // output until the process exits.
        setbuf(stdout, nil)

        // main() is called synchronously on the main thread by Swift's @main
        // machinery, so assumeIsolated is safe here.
        // dispatchMain() is the correct run-forever primitive for headless CLI
        // tools: it hands control to libdispatch's main queue so
        // NWBrowser/NWListener callbacks (dispatched onto the main queue) fire.
        MainActor.assumeIsolated { run() }
        dispatchMain()
    }

    @MainActor
    static func run() {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let opts = CLIOptions.parse(CommandLine.arguments, defaultShell: shell)

        UserDefaults.standard.set(opts.name, forKey: "peerDropDisplayName")
        HeadlessPlatform.register(deviceName: opts.name)

        let cm = ConnectionManager()
        let store = cm.trustedContactStore
        var bag = Set<AnyCancellable>()

        let bridge = ProcessBridge(command: opts.command)
        let session = AgentSession(bridge: bridge, connectionManager: cm, store: store)
        bridge.onMessage = { [weak session] text in session?.broadcast(text) }
        session.wire()

        bridge.onExit = { code in
            print("session ended (exit \(code))")
            if opts.restart {
                print("restarting…")
                Task { @MainActor in bridge.start() }
            } else {
                exit(code)
            }
        }

        print("peerdrop-cli ready · fingerprint \(IdentityKeyManager.shared.fingerprint)")
        print("wrapping: \(opts.command.joined(separator: " "))")
        print("advertising as \"\(opts.name)\" — waiting for a connection…")

        // Trust-gated incoming connection handler.
        cm.$pendingIncomingRequest
            .compactMap { $0 }
            .sink { req in
                let key = req.peerIdentity.identityPublicKey ?? Data()
                switch AgentSession.decideTrust(identityKey: key, store: store) {
                case .reject:
                    print("rejecting blocked peer \(req.peerIdentity.displayName)")
                    cm.rejectConnection()
                case .autoAccept, .enroll:
                    cm.acceptConnection()
                }
            }
            .store(in: &bag)

        // One-time SAS enrollment prompt for new local-Wi-Fi peers.
        cm.$pendingLocalFirstTrust
            .compactMap { $0 }
            .sink { pending in
                Task.detached {
                    print("\nPair with \(pending.senderDisplayName)?")
                    print("SAS: \(pending.sas ?? "n/a")  (verify it matches the phone)")
                    print("Approve? [y/N] ", terminator: "")
                    let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased()
                    await MainActor.run {
                        if answer == "y" {
                            cm.approveLocalFirstTrust(fingerprint: pending.fingerprint)
                            print("paired ✓ — future connections auto-accept")
                        } else {
                            cm.blockLocalFirstTrust(fingerprint: pending.fingerprint)
                            print("rejected")
                        }
                    }
                }
            }
            .store(in: &bag)

        bridge.start()
        cm.startDiscovery()

        installSignalHandlers(bridge: bridge, retained: &bag)
        retained = (cm, session as Any, bag)
    }

    /// Installs DispatchSource signal handlers for SIGINT and SIGTERM that
    /// cleanly terminate the child process before exiting.
    ///
    /// The signal sources must be retained for their lifetime; they are stored
    /// in the caller's `bag` via an opaque wrapper so ARC keeps them alive.
    @MainActor
    private static func installSignalHandlers(bridge: ProcessBridge, retained bag: inout Set<AnyCancellable>) {
        // Tell the kernel to ignore the default SIGINT/SIGTERM actions so our
        // DispatchSource handlers get a chance to run instead of the process
        // being killed immediately by the default handler.
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        intSource.setEventHandler {
            bridge.terminate()
            exit(0)
        }
        intSource.resume()

        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termSource.setEventHandler {
            bridge.terminate()
            exit(0)
        }
        termSource.resume()

        // Wrap the sources in a custom Cancellable so they can live inside
        // the AnyCancellable bag and be released when the bag is torn down.
        struct SourceRetainer: Cancellable {
            let sources: [any DispatchSourceSignal]
            func cancel() { sources.forEach { $0.cancel() } }
        }
        AnyCancellable(SourceRetainer(sources: [intSource, termSource]).cancel)
            .store(in: &bag)
    }
}
