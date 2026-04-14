import Foundation
import CryptoKit

/// Hashcash-style Proof-of-Work to prevent relay abuse.
/// Normal usage: ~50-100ms per proof. Bulk spamming: prohibitively expensive.
enum ProofOfWork {

    /// Generate a proof of work for the given challenge.
    /// Finds a nonce such that SHA256(challenge + nonce) has `difficulty` leading zero bits.
    static func generate(challenge: String, difficulty: Int = 16, maxIterations: Int = 10_000_000) -> UInt64? {
        let challengeData = Data(challenge.utf8)
        for nonce in UInt64(0)..<UInt64(maxIterations) {
            var data = challengeData
            withUnsafeBytes(of: nonce.bigEndian) { data.append(contentsOf: $0) }
            let hash = SHA256.hash(data: data)
            if hasLeadingZeroBits(hash: hash, count: difficulty) {
                return nonce
            }
        }
        return nil
    }

    /// Verify a proof of work.
    static func verify(challenge: String, proof: UInt64, difficulty: Int = 16) -> Bool {
        var data = Data(challenge.utf8)
        withUnsafeBytes(of: proof.bigEndian) { data.append(contentsOf: $0) }
        let hash = SHA256.hash(data: data)
        return hasLeadingZeroBits(hash: hash, count: difficulty)
    }

    private static func hasLeadingZeroBits(hash: SHA256.Digest, count: Int) -> Bool {
        let bytes = Array(hash)
        var zeroBits = 0
        for byte in bytes {
            if byte == 0 {
                zeroBits += 8
            } else {
                zeroBits += byte.leadingZeroBitCount
                break
            }
            if zeroBits >= count { return true }
        }
        return zeroBits >= count
    }
}
