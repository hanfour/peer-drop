import Foundation
import CommonCrypto
import Security

/// PBKDF2-HMAC-SHA256 password hashing. Format: "pbkdf2$<iters>$<saltB64>$<hashB64>".
public enum PasswordHash {
    private static let iters: UInt32 = 200_000
    public static func make(_ password: String) -> String {
        var salt = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt)
        let hash = derive(password, salt: salt, iters: iters)
        return "pbkdf2$\(iters)$\(Data(salt).base64EncodedString())$\(Data(hash).base64EncodedString())"
    }
    public static func verify(_ password: String, against stored: String) -> Bool {
        let parts = stored.split(separator: "$")
        guard parts.count == 4, parts[0] == "pbkdf2",
              let iters = UInt32(parts[1]),
              let salt = Data(base64Encoded: String(parts[2])),
              let expected = Data(base64Encoded: String(parts[3])) else { return false }
        let actual = derive(password, salt: Array(salt), iters: iters)
        guard actual.count == expected.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(actual, Array(expected)) { diff |= a ^ b }   // constant-time
        return diff == 0
    }
    private static func derive(_ password: String, salt: [UInt8], iters: UInt32) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 32)
        let pwLen = password.utf8.count
        _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, pwLen,
                                 salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                 iters, &out, out.count)
        return out
    }
}
