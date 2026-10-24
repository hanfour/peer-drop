import Foundation

/// The first WebSocket text frame on `/rv` (the token never appears in the URL):
///
///     {"v":1,"t":"<token b64url, 43>","pow":{"h":<hour>,"n":"<nonce>"},"s":"<16 bytes b64url, 22>"}
///
/// Compact, fixed key order, ≤ 512 UTF-8 bytes (`RV_MAX_FRAME_BYTES`).
public enum RendezvousFirstFrame {
    public static let maxFrameBytes = 512

    public enum BuildError: Error, Equatable {
        case invalidSessionTag
        case frameTooLarge
    }

    /// Solves the PoW for `now` (client hour rule) and builds the frame.
    public static func build(token: Data, now: Date, sessionTags: RendezvousSessionTagStore) throws -> String {
        let encodedToken = try RendezvousToken.encoded(token)  // validates length
        let hour = RendezvousProofOfWork.currentHour(now: now)
        let nonce = try RendezvousProofOfWork.solve(tokenBytes: token, hour: hour)
        return try build(encodedToken: encodedToken, hour: hour, nonce: nonce, sessionTag: sessionTags.tag(for: token))
    }

    /// Assembles a frame from pre-computed parts.
    public static func build(token: Data, hour: Int, nonce: String, sessionTag: String) throws -> String {
        try build(encodedToken: RendezvousToken.encoded(token), hour: hour, nonce: nonce, sessionTag: sessionTag)
    }

    private static func build(encodedToken: String, hour: Int, nonce: String, sessionTag: String) throws -> String {
        guard RendezvousToken.decodeBase64URL(sessionTag, expectedLength: RendezvousSessionTagStore.tagByteCount) != nil else {
            throw BuildError.invalidSessionTag
        }
        let frame = #"{"v":1,"t":""# + encodedToken
            + #"","pow":{"h":"# + String(hour) + #","n":"# + jsonString(nonce)
            + #"},"s":""# + sessionTag + #""}"#
        guard frame.utf8.count <= maxFrameBytes else { throw BuildError.frameTooLarge }
        return frame
    }

    /// JSON string literal (quoted, escaped) via Foundation's encoder.
    private static func jsonString(_ s: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(s), let out = String(data: data, encoding: .utf8) else { return "\"\"" }
        return out
    }
}

/// Issues the `s` session tag for the `/rv` first frame.
///
/// Rules (Worker contract): `s` = 16 random bytes, canonical base64url; the
/// SAME `s` for the same token within one app run (so a reconnect after the
/// 2 h cap or a network blip takes back our slot), a fresh `s` for every new
/// run (new store instance; nothing is persisted), and never the same `s` for
/// two different tokens (that would link two rooms to one client). Issued tags
/// are remembered for the whole run, even after `forget`, so a tag is never
/// handed out twice. In-memory only; never logged.
public final class RendezvousSessionTagStore: @unchecked Sendable {
    public static let tagByteCount = 16

    private let random: RendezvousRandomSource
    private let lock = NSLock()
    private var byToken: [Data: String] = [:]
    private var issued: Set<String> = []

    public init(random: RendezvousRandomSource = SystemRendezvousRandom.shared) {
        self.random = random
    }

    public func tag(for token: Data) -> String {
        lock.lock(); defer { lock.unlock() }
        if let existing = byToken[token] { return existing }
        var candidate: String
        var attempts = 0
        repeat {
            attempts += 1
            // 128-bit tags collide with negligible probability; a source that
            // keeps repeating itself is broken and must not be papered over.
            precondition(attempts <= 64, "RendezvousSessionTagStore: random source is not producing fresh bytes")
            candidate = RendezvousToken.encodeBase64URL(random.randomBytes(count: Self.tagByteCount))
        } while issued.contains(candidate)
            || RendezvousToken.decodeBase64URL(candidate, expectedLength: Self.tagByteCount) == nil
        issued.insert(candidate)
        byToken[token] = candidate
        return candidate
    }

    /// Drop the token→tag mapping (e.g. after the day rolled over). A later
    /// `tag(for:)` for the same token issues a new, never-before-used tag.
    public func forget(tokens: [Data]) {
        lock.lock(); defer { lock.unlock() }
        for t in tokens { byToken.removeValue(forKey: t) }
    }
}
