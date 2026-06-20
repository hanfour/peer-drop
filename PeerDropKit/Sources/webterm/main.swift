import Foundation

// Load config from environment variables or defaults.
// WEBTERM_PASSWORD_HASH: PBKDF2 hash from PasswordHash.make(_:).
// WEBTERM_PORT: TCP port (default 7681).
// WEBTERM_HOST: Expected host header (default "localhost").
// WEBTERM_SECRET: 32-byte hex-encoded session HMAC secret. If absent, a random secret is generated.

let env = ProcessInfo.processInfo.environment

let port = env["WEBTERM_PORT"].flatMap(Int.init) ?? 7681
let expectedHost = env["WEBTERM_HOST"] ?? "localhost"

let sessionSecret: Data
if let hexSecret = env["WEBTERM_SECRET"], hexSecret.count == 64 {
    var bytes = [UInt8]()
    var idx = hexSecret.startIndex
    while idx < hexSecret.endIndex {
        let nextIdx = hexSecret.index(idx, offsetBy: 2)
        if let byte = UInt8(hexSecret[idx..<nextIdx], radix: 16) {
            bytes.append(byte)
        }
        idx = nextIdx
    }
    sessionSecret = Data(bytes)
} else {
    sessionSecret = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
}

let auth: WebTermConfig.Auth
if let hash = env["WEBTERM_PASSWORD_HASH"] {
    auth = .password(hash: hash)
} else if let aud = env["CF_ACCESS_AUD"],
          let team = env["CF_ACCESS_TEAM"],
          let email = env["CF_ACCESS_OWNER_EMAIL"] {
    auth = .cloudflare(team: team, aud: aud, ownerEmail: email)
} else {
    // Default: require password "changeme" (warn loudly).
    print("WARNING: No WEBTERM_PASSWORD_HASH set. Using insecure default password 'changeme'.")
    auth = .password(hash: PasswordHash.make("changeme"))
}

let cfg = WebTermConfig(
    port: port,
    expectedHost: expectedHost,
    auth: auth,
    sessionSecret: sessionSecret,
    presets: []
)

let app = try buildApplication(cfg)
try await app.runService()
