import Foundation
import CryptoKit

/// Proof-of-work for `POST /v2/messages/:mailboxId` that the worker issues the challenge for.
///
/// The hash covers `utf8(challenge) || utf8(mailboxId) || SHA256(utf8(ciphertext)) || proof` (proof as
/// 8 bytes, big-endian), so a proof cannot be reused for another mailbox or another ciphertext. `ciphertext`
/// is the base64 string exactly as sent in the JSON body.
public enum MailboxProofOfWork {

    public static func generate(
        challenge: String,
        mailboxId: String,
        ciphertext: String,
        difficulty: Int,
        maxIterations: Int = 10_000_000
    ) -> UInt64? {
        let prefix = preimagePrefix(challenge: challenge, mailboxId: mailboxId, ciphertext: ciphertext)
        for proof in UInt64(0)..<UInt64(maxIterations) {
            if meetsDifficulty(prefix: prefix, proof: proof, difficulty: difficulty) { return proof }
        }
        return nil
    }

    /// Runs the CPU-bound search off the calling actor, like `ProofOfWork.generate(...) async`.
    public static func generate(
        challenge: String,
        mailboxId: String,
        ciphertext: String,
        difficulty: Int,
        maxIterations: Int = 10_000_000
    ) async -> UInt64? {
        await Task.detached(priority: .userInitiated) {
            generate(challenge: challenge, mailboxId: mailboxId, ciphertext: ciphertext, difficulty: difficulty, maxIterations: maxIterations)
        }.value
    }

    public static func verify(challenge: String, mailboxId: String, ciphertext: String, proof: UInt64, difficulty: Int) -> Bool {
        let prefix = preimagePrefix(challenge: challenge, mailboxId: mailboxId, ciphertext: ciphertext)
        return meetsDifficulty(prefix: prefix, proof: proof, difficulty: difficulty)
    }

    private static func preimagePrefix(challenge: String, mailboxId: String, ciphertext: String) -> Data {
        var data = Data(challenge.utf8)
        data.append(Data(mailboxId.utf8))
        data.append(Data(SHA256.hash(data: Data(ciphertext.utf8))))
        return data
    }

    private static func meetsDifficulty(prefix: Data, proof: UInt64, difficulty: Int) -> Bool {
        var data = prefix
        withUnsafeBytes(of: proof.bigEndian) { data.append(contentsOf: $0) }
        var zeroBits = 0
        for byte in SHA256.hash(data: data) {
            if byte == 0 { zeroBits += 8; if zeroBits >= difficulty { return true }; continue }
            zeroBits += byte.leadingZeroBitCount
            break
        }
        return zeroBits >= difficulty
    }
}
