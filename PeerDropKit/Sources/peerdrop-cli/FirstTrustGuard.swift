import Foundation
import Combine
import CryptoKit
import PeerDropCore

/// Short-term CLI mitigation for #173 (the 6-digit local SAS is derived only
/// from static public keys, so an attacker can grind a key whose SAS matches
/// the real phone's and race it to the prompt):
///
/// (a) One first-trust pairing at a time. ConnectionManager surfaces a single
///     `pendingLocalFirstTrust` and silently leaves any other new peer gated.
///     Here, a peer whose verdict becomes `.firstTrust` while a prompt is open
///     for a DIFFERENT connection is rejected and disconnected, and the
///     operator is told — a second new device showing up mid-pairing is itself
///     a warning sign.
/// (b) The prompt also prints the full SHA-256 fingerprint of the identity
///     key the peer actually used in the handshake, for comparison with the
///     phone's.
@MainActor
final class FirstTrustGuard {

    private let cm: ConnectionManager
    private let log: (String) -> Void
    private var watchers: [String: AnyCancellable] = [:]

    init(connectionManager: ConnectionManager, log: ((String) -> Void)? = nil) {
        self.cm = connectionManager
        self.log = log ?? { print($0) }
    }

    /// Start watching a newly connected peer's pinning verdict.
    func watch(_ peerID: String) {
        guard let conn = cm.connection(for: peerID) else { return }
        // @Published emits in willSet: re-evaluate on the next main-queue turn,
        // after the verdict is stored and the prompt (if any) was surfaced.
        watchers[peerID] = conn.$pinningVerdict
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluate(peerID) }
            }
    }

    func stopWatching(_ peerID: String) {
        watchers[peerID] = nil
    }

    /// Reject `peerID` if it is a first-trust peer while a pairing prompt is
    /// open for another connection.
    func evaluate(_ peerID: String) {
        guard let conn = cm.connection(for: peerID),
              conn.pinningVerdict == .firstTrust,
              let pending = cm.pendingLocalFirstTrust,
              !Self.isPromptConnection(conn, pending: pending)
        else { return }
        let name = TerminalSanitizer.sanitize(conn.peerIdentity.displayName)
        log("\nrejected second new device \"\(name)\": another pairing prompt is already open. "
            + "Only one new device can pair at a time. If you expected \"\(name)\", answer n to the "
            + "current prompt and reconnect it.")
        watchers[peerID] = nil
        Task { [cm] in await cm.disconnect(from: peerID) }
    }

    /// The connection a pending prompt is about: same hello key, and the
    /// prompt's fingerprint was computed from THIS connection's handshake key.
    static func isPromptConnection(_ conn: PeerConnection, pending: PendingFirstContact) -> Bool {
        guard let handshakeKey = conn.handshakePeerIdentityKey,
              conn.peerIdentity.identityPublicKey == pending.senderIdentityKey
        else { return false }
        return ConnectionManager.computeFingerprint(of: handshakeKey) == pending.fingerprint
    }

    static func promptConnection(for pending: PendingFirstContact, cm: ConnectionManager) -> PeerConnection? {
        cm.connections.values.first {
            $0.pinningVerdict == .firstTrust && isPromptConnection($0, pending: pending)
        }
    }

    /// Full SHA-256 of `key`, uppercase hex, in 16 groups of 4.
    nonisolated static func keyFingerprint(_ key: Data) -> String {
        let hex = SHA256.hash(data: key).map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: hex.count, by: 4).map { i -> String in
            let start = hex.index(hex.startIndex, offsetBy: i)
            return String(hex[start..<hex.index(start, offsetBy: 4)])
        }.joined(separator: " ")
    }

    /// Local-Wi-Fi pairing prompt, with the full fingerprint of the handshake
    /// key of the connection the prompt is about.
    static func promptLines(for pending: PendingFirstContact, cm: ConnectionManager) -> [String] {
        let handshakeKey = promptConnection(for: pending, cm: cm)?.handshakePeerIdentityKey
        return PairingPrompt.lines(
            displayName: pending.senderDisplayName,
            sas: pending.sas ?? "n/a",
            fingerprint: pending.fingerprint,
            isRelay: false,
            keyFingerprint: handshakeKey.map(keyFingerprint))
    }
}
