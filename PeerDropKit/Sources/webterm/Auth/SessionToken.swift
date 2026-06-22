import Foundation
import CryptoKit

/// Signed session token with sliding idle-timeout and absolute session cap.
///
/// Token format: `"<subject>.<issuedAtUnix>.<expUnix>.<hmacB64url>"` (4 dot-parts; HMAC-SHA256).
///
/// - `issuedAt`: original issue time, carried across all slides — enforces the absolute session cap.
/// - `exp`: sliding expiry — reset on every slide; idle-expiry check is `exp > now`.
///
/// Note: subject must not contain '.' (the token is dot-delimited; webterm uses the fixed 'owner' subject).
public enum SessionToken {

    // MARK: - Issue

    /// Issue a new token.
    ///
    /// - Parameters:
    ///   - subject: The identity claim (no dots allowed).
    ///   - idleTTL: Seconds until the token expires due to inactivity.
    ///   - secret: HMAC-SHA256 secret.
    ///   - now: The current time (injectable for testing).
    public static func issue(
        subject: String,
        idleTTL: TimeInterval,
        secret: Data,
        now: Date = Date()
    ) -> String {
        let issuedAt = Int(now.timeIntervalSince1970)
        let exp = Int(now.addingTimeInterval(idleTTL).timeIntervalSince1970)
        let body = "\(subject).\(issuedAt).\(exp)"
        return "\(body).\(sign(body, secret: secret))"
    }

    // MARK: - Verify

    /// Verify a token, returning the subject on success or nil on any failure.
    ///
    /// Rejects if:
    /// - The MAC is invalid (constant-time check).
    /// - The token is idle-expired (`exp <= now`).
    /// - The absolute session cap is exceeded (`now - issuedAt > maxAge`).
    ///
    /// - Parameters:
    ///   - token: The raw token string.
    ///   - secret: HMAC-SHA256 secret.
    ///   - maxAge: Maximum allowed session lifetime regardless of sliding. Default 12 hours.
    ///   - now: The current time (injectable for testing).
    public static func verify(
        _ token: String,
        secret: Data,
        maxAge: TimeInterval = 12 * 3600,
        now: Date = Date()
    ) -> String? {
        guard let parts = parse(token), parts.count == 4 else { return nil }
        let body = "\(parts[0]).\(parts[1]).\(parts[2])"
        guard let macData = base64urlDecode(parts[3]) else { return nil }
        let key = SymmetricKey(data: secret)
        // Constant-time MAC check (avoids a timing oracle on the signature).
        guard HMAC<SHA256>.isValidAuthenticationCode(
            macData, authenticating: Data(body.utf8), using: key
        ) else { return nil }

        guard let issuedAt = Int(parts[1]), let exp = Int(parts[2]) else { return nil }
        let nowUnix = Int(now.timeIntervalSince1970)

        // Idle-expiry check.
        guard exp > nowUnix else { return nil }

        // Absolute-cap check.
        guard nowUnix - issuedAt <= Int(maxAge) else { return nil }

        return parts[0] // subject
    }

    // MARK: - Slide

    /// Slide (renew) a token: if it verifies, issue a replacement with the SAME `issuedAt`
    /// and `exp = now + idleTTL`. Preserving `issuedAt` enforces the absolute session cap
    /// across unlimited slides.
    ///
    /// Returns `nil` if the token is invalid, idle-expired, or has exceeded `maxAge`.
    ///
    /// - Parameters:
    ///   - token: The current raw token string.
    ///   - secret: HMAC-SHA256 secret.
    ///   - idleTTL: The new idle window in seconds.
    ///   - maxAge: Maximum allowed session lifetime.
    ///   - now: The current time (injectable for testing).
    public static func slide(
        _ token: String,
        secret: Data,
        idleTTL: TimeInterval,
        maxAge: TimeInterval = 12 * 3600,
        now: Date = Date()
    ) -> String? {
        guard let parts = parse(token), parts.count == 4 else { return nil }
        // Must fully verify (MAC + idle + absolute cap) before we slide.
        guard verify(token, secret: secret, maxAge: maxAge, now: now) != nil else { return nil }
        guard let issuedAt = Int(parts[1]) else { return nil }

        let subject = parts[0]
        let newExp = Int(now.addingTimeInterval(idleTTL).timeIntervalSince1970)
        let body = "\(subject).\(issuedAt).\(newExp)"
        return "\(body).\(sign(body, secret: secret))"
    }

    // MARK: - Private helpers

    /// Split the token into its 4 dot-separated parts: [subject, issuedAt, exp, mac].
    /// Returns nil if the count is wrong.
    private static func parse(_ token: String) -> [String]? {
        // subject has no dots; split up to 4 parts (limit splits at 3 so the mac isn't split further).
        let parts = token.split(separator: ".", maxSplits: 3, omittingEmptySubsequences: false)
            .map(String.init)
        return parts.count == 4 ? parts : nil
    }

    private static func sign(_ body: String, secret: Data) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(body.utf8), using: SymmetricKey(data: secret))
        return Data(mac).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64urlDecode(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b.append("=") }
        return Data(base64Encoded: b)
    }
}
