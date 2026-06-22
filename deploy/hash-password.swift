// webterm password-hash helper.
//
// Generates a PBKDF2-HMAC-SHA256 hash (200_000 iterations, 16-byte random salt)
// in the format webterm's PasswordHash.verify expects:
//     pbkdf2$200000$<base64 salt>$<base64 derived key>
//
// Usage:
//     swift deploy/hash-password.swift
// It prompts for a password WITHOUT echoing it (getpass), so the password
// never lands in your shell history or the process argv. Paste the printed
// hash into WEBTERM_PASSWORD_HASH (launchd plist or the foreground env).

import Foundation
import CommonCrypto
import Security

func pbkdf2(_ password: String) -> String {
    var salt = [UInt8](repeating: 0, count: 16)
    _ = SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt)
    var out = [UInt8](repeating: 0, count: 32)
    CCKeyDerivationPBKDF(
        CCPBKDFAlgorithm(kCCPBKDF2),
        password, password.utf8.count,
        salt, salt.count,
        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
        200_000,
        &out, out.count
    )
    return "pbkdf2$200000$\(Data(salt).base64EncodedString())$\(Data(out).base64EncodedString())"
}

guard let raw = getpass("Choose a webterm password: ") else {
    FileHandle.standardError.write(Data("error: could not read password\n".utf8))
    exit(1)
}
let password = String(cString: raw)
guard password.count >= 8 else {
    FileHandle.standardError.write(Data("error: password too short (use 16+ chars)\n".utf8))
    exit(1)
}
print(pbkdf2(password))
