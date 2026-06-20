import Foundation
import CryptoKit

/// Signed session token: "<subject>.<expiryUnix>.<hmacB64url>" (HMAC-SHA256).
///
/// Note: subject must not contain '.' (the token is dot-delimited; webterm uses the fixed 'owner' subject).
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
        guard let macData = base64urlDecode(String(parts[2])) else { return nil }
        let key = SymmetricKey(data: secret)
        // Constant-time MAC check (avoids a timing oracle on the signature).
        guard HMAC<SHA256>.isValidAuthenticationCode(macData, authenticating: Data(body.utf8), using: key) else {
            return nil
        }
        guard let exp = Int(parts[1]), Date(timeIntervalSince1970: TimeInterval(exp)) > now else { return nil }
        return String(parts[0])
    }
    private static func sign(_ body: String, secret: Data) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(body.utf8), using: SymmetricKey(data: secret))
        return Data(mac).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64urlDecode(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b.append("=") }
        return Data(base64Encoded: b)
    }
}
