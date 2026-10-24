import Foundation
import CryptoKit

/// Client side of the `/rv` anonymous proof-of-work. Mirrors
/// `cloudflare-worker/src/rendezvousPow.ts`; both sides are pinned by the shared
/// vectors in `cloudflare-worker/test-vectors/rendezvous-pow.json`.
///
///     SHA256(token(32) ‖ UInt64BE(hour) ‖ utf8(nonce)) has ≥ difficulty leading zero bits
///
/// The server accepts `hour ∈ {floor(now/3600), floor(now/3600) − 1}`; the
/// client uses `floor((now − 600)/3600)` so hour-boundary races and ±10 min
/// skew stay in that window. Nonce: 1…64 UTF-16 code units (JS `length`).
///
/// `solve` is CPU-bound — always run it off the main actor.
///
/// Honest limit (plan Ruling 8): 16 bits is cheap for an attacker; this is a
/// speed bump, not an abuse ceiling.
public enum RendezvousProofOfWork {
    public static let defaultDifficultyBits = 16
    public static let maxNonceLength = 64
    public static let clientBackdateSeconds = 600
    public static let defaultMaxAttempts: UInt64 = 1 << 26

    public enum SolveError: Error, Equatable {
        case invalidInput
        case invalidNonce
        case exhausted
    }

    /// Client hour rule: `floor((unixSeconds − 600) / 3600)`, clamped at 0.
    public static func currentHour(now: Date) -> Int {
        let h = Int(((now.timeIntervalSince1970 - Double(clientBackdateSeconds)) / 3600).rounded(.down))
        return max(h, 0)
    }

    /// Mirror of the server's hour window (used by tests and self-checks).
    public static func serverAcceptsHour(_ hour: Int, now: Date) -> Bool {
        let cur = Int((now.timeIntervalSince1970 / 3600).rounded(.down))
        return hour == cur || hour == cur - 1
    }

    public static func leadingZeroBits(tokenBytes: Data, hour: Int, nonce: String) -> Int {
        var input = Data(tokenBytes)
        input.append(bigEndian8(UInt64(bitPattern: Int64(hour))))
        input.append(Data(nonce.utf8))
        var zeros = 0
        for byte in SHA256.hash(data: input) {
            if byte == 0 { zeros += 8; continue }
            zeros += byte.leadingZeroBitCount
            break
        }
        return zeros
    }

    static func isWellFormedNonce(_ nonce: String) -> Bool {
        let n = nonce.utf16.count
        return n >= 1 && n <= maxNonceLength
    }

    /// Shape + work check (no hour window).
    public static func verify(tokenBytes: Data, hour: Int, nonce: String,
                              difficultyBits: Int = defaultDifficultyBits) -> Bool {
        guard tokenBytes.count == RendezvousToken.byteCount, hour >= 0, isWellFormedNonce(nonce) else { return false }
        return leadingZeroBits(tokenBytes: tokenBytes, hour: hour, nonce: nonce) >= difficultyBits
    }

    /// Exactly the server's verdict for `{h, n}` at `now` (shape, window, work).
    public static func verifyClaim(tokenBytes: Data, hour: Int, nonce: String, now: Date) -> Bool {
        serverAcceptsHour(hour, now: now) && verify(tokenBytes: tokenBytes, hour: hour, nonce: nonce)
    }

    /// Finds a nonce. `nonceGenerator(i)` maps attempt `i` to a candidate
    /// (default: base-36 of `i`, ASCII, ≤ 13 chars); deterministic for a given
    /// generator, so tests are reproducible.
    public static func solve(
        tokenBytes: Data,
        hour: Int,
        difficultyBits: Int = defaultDifficultyBits,
        maxAttempts: UInt64 = defaultMaxAttempts,
        nonceGenerator: (UInt64) -> String = { String($0, radix: 36) }
    ) throws -> String {
        guard tokenBytes.count == RendezvousToken.byteCount, hour >= 0,
              (0...256).contains(difficultyBits) else { throw SolveError.invalidInput }
        var i: UInt64 = 0
        while i < maxAttempts {
            let nonce = nonceGenerator(i)
            guard isWellFormedNonce(nonce) else { throw SolveError.invalidNonce }
            if leadingZeroBits(tokenBytes: tokenBytes, hour: hour, nonce: nonce) >= difficultyBits {
                return nonce
            }
            i += 1
        }
        throw SolveError.exhausted
    }
}
