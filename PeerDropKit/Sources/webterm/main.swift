import Foundation

// Load config from environment variables or defaults.
// WEBTERM_PASSWORD_HASH: PBKDF2 hash from PasswordHash.make(_:).
// WEBTERM_PORT: TCP port (default 7681).
// WEBTERM_HOST: Expected hostname for Origin-header check (default "localhost"; set to your real public hostname in production).
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

// Load presets from a JSON file specified by WEBTERM_PRESETS.
// If the env var is unset → no custom presets (only the built-in "shell" preset).
// If set but the file is missing or malformed → print a WARNING and continue with [].
var presets: [Preset] = []
if let presetsPath = env["WEBTERM_PRESETS"] {
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: presetsPath))
        presets = try JSONDecoder().decode([Preset].self, from: data)
        print("webterm: Loaded \(presets.count) preset(s) from \(presetsPath).")
    } catch {
        print("WARNING: could not load WEBTERM_PRESETS from \(presetsPath): \(error). Continuing with no custom presets.")
    }
}

let cfg = WebTermConfig(
    port: port,
    expectedHost: expectedHost,
    auth: auth,
    sessionSecret: sessionSecret,
    presets: presets
)

// In cloudflare mode, fetch the team JWKS before starting the server.
// This is the composition root for CfAccessVerifier: we resolve the async
// network call here so that buildApplication receives a ready verifier.
// If the fetch fails we print a clear error and exit non-zero — the operator
// must fix the team name / network before retrying. Fail-closed.
var cfVerifier: CfAccessVerifier? = nil
if case .cloudflare(let team, let aud, let ownerEmail) = auth {
    do {
        let keys = try await CfAccessKeys.fetch(team: team)
        cfVerifier = CfAccessVerifier(audience: aud, ownerEmail: ownerEmail, keys: keys)
        print("webterm: Cloudflare Access JWKS loaded for team '\(team)'. Auto-refresh every 3600s.")
    } catch let error as CfAccessKeysError {
        print("ERROR: \(error)")
        print("ERROR: Cloudflare-delegated auth cannot function. Fix CF_ACCESS_TEAM and network connectivity, then restart.")
        exit(1)
    } catch {
        print("ERROR: Failed to fetch Cloudflare Access JWKS for team '\(team)': \(error)")
        print("ERROR: Cloudflare-delegated auth cannot function. Fix CF_ACCESS_TEAM and network connectivity, then restart.")
        exit(1)
    }
}

// Retain the JWKS refresh task for the process lifetime so it isn't cancelled on drop.
var jwksRefreshTask: Task<Void, Never>? = nil
if case .cloudflare(let team, _, _) = auth, let verifier = cfVerifier {
    jwksRefreshTask = CfAccessKeys.startPeriodicRefresh(team: team, into: verifier.source)
}

let app = try buildApplication(cfg, cfVerifier: cfVerifier, autostartPresets: true)
try await app.runService()
