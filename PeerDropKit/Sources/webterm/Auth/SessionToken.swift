import Foundation
import CryptoKit

/// Signed session token: "<subject>.<expiryUnix>.<hmacB64url>" (HMAC-SHA256).
public enum SessionToken {
    public static func issue(subject: String, ttl: TimeInterval, secret: Data, now: Date = Date()) -> String {
        let exp = Int(now.addingTimeInterval(ttl).timeIntervalSince1970)
        let body = "\(subject).\(exp)"
        return "\(body).\(sign(body, secret: secret))"
    }
    public static func verify(_ token: String, secret: Data, now: Date = Date()) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        let body = "\(parts[0]).\(parts[1])"
        guard sign(body, secret: secret) == String(parts[2]) else { return nil }
        guard let exp = Int(parts[1]), Date(timeIntervalSince1970: TimeInterval(exp)) > now else { return nil }
        return String(parts[0])
    }
    private static func sign(_ body: String, secret: Data) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(body.utf8), using: SymmetricKey(data: secret))
        return Data(mac).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
