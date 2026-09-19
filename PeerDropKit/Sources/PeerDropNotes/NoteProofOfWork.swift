import Foundation
import CryptoKit
import PeerDropSecurity

/// Hashcash for `POST /v3/notes`: the worker hands out a single-use
/// challenge and expects `sha256(utf8(message) ‖ nonce BE8)` to start
/// with 16 zero bits, where `message` binds the challenge, the recipient
/// and the exact envelope bytes. Reuses the existing `ProofOfWork` search.
public enum NoteProofOfWork {
    public static let difficulty = 16

    public static func message(challenge: String, recipientAccountId: String, envelopeBytes: Data) -> String {
        let hex = SHA256.hash(data: envelopeBytes).map { String(format: "%02x", $0) }.joined()
        return "\(challenge)|\(recipientAccountId)|\(hex)"
    }

    /// Runs off the calling actor (see `ProofOfWork.generate(...) async`).
    public static func solve(challenge: String, recipientAccountId: String, envelopeBytes: Data) async -> UInt64? {
        await ProofOfWork.generate(challenge: message(challenge: challenge, recipientAccountId: recipientAccountId, envelopeBytes: envelopeBytes), difficulty: difficulty)
    }
}
