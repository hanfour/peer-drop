import Foundation
import Combine
import CryptoKit
import PeerDropCore

/// Local-Wi-Fi first-trust (SAS) pairing for the CLI, including the
/// short-term mitigation for #173 (the 6-digit SAS is derived only from static
/// public keys, so an attacker can grind a key whose SAS matches the real
/// phone's and race it to the prompt):
///
/// - One pairing at a time. ConnectionManager surfaces a single
///   `pendingLocalFirstTrust` and silently leaves any other new peer gated.
///   Here a peer whose verdict becomes `.firstTrust` while a prompt is open for
///   a DIFFERENT connection is disconnected, and the operator is told (with
///   that device's fingerprint) — a second new device mid-pairing is itself a
///   warning sign.
/// - The prompt shows, in the phone's own format, the fingerprint of the key
///   the peer actually used in the handshake. The phone's Security screen
///   shows its own fingerprint, so a ground key is caught there.
/// - "n" dismisses WITHOUT blocking: an attacker can reuse the real phone's
///   display name, and blocking (ConnectionManager.blockLocalFirstTrust blocks
///   the hello-claimed key) could permanently lock out the real phone, with no
///   unblock in the CLI.
/// - A prompt whose device disconnects is closed.
@MainActor
final class FirstTrustGuard {

    private let cm: ConnectionManager
    private let log: (String) -> Void
    private var watchers: [String: AnyCancellable] = [:]

    init(connectionManager: ConnectionManager, log: ((String) -> Void)? = nil) {
        self.cm = connectionManager
        self.log = log ?? { print($0) }
    }

    // MARK: - Watching connections

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

    /// Call when `peerID` disconnected. If no live connection owns the open
    /// prompt any more, the prompt is closed (without blocking anything).
    func stopWatching(_ peerID: String) {
        watchers[peerID] = nil
        guard let pending = cm.pendingLocalFirstTrust,
              Self.promptConnection(for: pending, cm: cm) == nil
        else { return }
        cm.pendingLocalFirstTrust = nil
        log("\nThe device that was pairing left before you answered — that pairing prompt is closed "
            + "(nothing was approved or blocked). Press Enter to continue.")
    }

    /// Disconnect `peerID` if it is a first-trust peer while a pairing prompt
    /// is open for another connection.
    func evaluate(_ peerID: String) {
        guard let conn = cm.connection(for: peerID),
              conn.pinningVerdict == .firstTrust,
              let pending = cm.pendingLocalFirstTrust,
              !Self.isPromptConnection(conn, pending: pending)
        else { return }
        let name = TerminalSanitizer.sanitize(conn.peerIdentity.displayName)
        let fp = conn.handshakePeerIdentityKey.map(Self.phoneFingerprint) ?? "unknown"
        log("\nAnother device is already pairing, so a second new device was rejected and disconnected: "
            + "\"\(name)\", key fingerprint \(fp). Before answering the current prompt, open Security "
            + "on your phone and compare its own fingerprint with the one shown in the prompt.")
        watchers[peerID] = nil
        Task { [cm] in await cm.disconnect(from: peerID) }
    }

    // MARK: - Answering the prompt

    /// Applies the operator's answer to `pending`. "y" approves; anything else
    /// dismisses the prompt and disconnects that device WITHOUT blocking its
    /// key. An answer for a prompt that is no longer open is ignored.
    func handleAnswer(_ answer: String?, for pending: PendingFirstContact) {
        guard cm.pendingLocalFirstTrust?.fingerprint == pending.fingerprint else {
            log("(that pairing prompt was already closed — answer ignored; if another prompt is showing, answer it again)")
            return
        }
        let normalized = answer?.trimmingCharacters(in: .whitespaces).lowercased()
        if normalized == "y" {
            cm.approveLocalFirstTrust(fingerprint: pending.fingerprint)
            log("paired ✓ — future connections auto-accept")
            return
        }
        let conn = Self.promptConnection(for: pending, cm: cm)
        cm.pendingLocalFirstTrust = nil
        if let conn {
            watchers[conn.id] = nil
            Task { [cm] in await cm.disconnect(from: conn.id) }
        }
        log("not paired — the device was disconnected (not blocked; it can try again)")
    }

    // MARK: - Prompt text

    /// The connection a pending prompt is about: same hello key, and the
    /// prompt's fingerprint was computed from THIS connection's handshake key.
    static func isPromptConnection(_ conn: PeerConnection, pending: PendingFirstContact) -> Bool {
        guard let handshakeKey = conn.handshakePeerIdentityKey,
              conn.peerIdentity.identityPublicKey == pending.senderIdentityKey
        else { return false }
        return phoneFingerprint(handshakeKey) == pending.fingerprint
    }

    static func promptConnection(for pending: PendingFirstContact, cm: ConnectionManager) -> PeerConnection? {
        cm.connections.values.first {
            $0.pinningVerdict == .firstTrust && isPromptConnection($0, pending: pending)
        }
    }

    /// The phone's fingerprint format (`IdentityKeyManager.fingerprint` /
    /// `TrustedContact.keyFingerprint`): first 10 bytes of SHA-256, uppercase
    /// hex, 5 groups of 4.
    nonisolated static func phoneFingerprint(_ key: Data) -> String {
        let hex = SHA256.hash(data: key).prefix(10).map { String(format: "%02X", $0) }.joined()
        return stride(from: 0, to: hex.count, by: 4).map { i -> String in
            let start = hex.index(hex.startIndex, offsetBy: i)
            return String(hex[start..<hex.index(start, offsetBy: 4)])
        }.joined(separator: " ")
    }

    /// Local-Wi-Fi pairing prompt. `ownFingerprint` is this CLI's fingerprint
    /// (`IdentityKeyManager.shared.fingerprint`), which the phone's pairing
    /// sheet shows as the key it received.
    static func promptLines(for pending: PendingFirstContact, cm: ConnectionManager, ownFingerprint: String) -> [String] {
        let handshakeKey = promptConnection(for: pending, cm: cm)?.handshakePeerIdentityKey
        return PairingPrompt.lines(
            displayName: pending.senderDisplayName,
            sas: pending.sas ?? "n/a",
            fingerprint: pending.fingerprint,
            isRelay: false,
            peerKeyFingerprint: handshakeKey.map(phoneFingerprint),
            ownFingerprint: ownFingerprint)
    }
}
