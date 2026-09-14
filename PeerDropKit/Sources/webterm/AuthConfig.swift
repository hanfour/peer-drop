import Foundation

/// Raised when the server's authentication mode cannot be resolved from the
/// environment. Every case is fatal: the server refuses to start rather than
/// fall back to a guessable default password.
enum AuthConfigError: Error, Equatable, CustomStringConvertible {
    /// Neither a password hash nor any Cloudflare Access variable was provided.
    case noAuthConfigured
    /// One or more — but not all — `CF_ACCESS_*` variables were provided, and no
    /// password hash. `missing` names the absent variables (stable order).
    case incompleteCloudflareConfig(missing: [String])

    var description: String {
        switch self {
        case .noAuthConfigured:
            return """
            No authentication configured. Refusing to start. \
            Set WEBTERM_PASSWORD_HASH (a PBKDF2 hash from PasswordHash.make(_:)) for \
            password auth, or set all of CF_ACCESS_TEAM, CF_ACCESS_AUD and \
            CF_ACCESS_OWNER_EMAIL for Cloudflare Access auth.
            """
        case .incompleteCloudflareConfig(let missing):
            return """
            Incomplete Cloudflare Access configuration. Refusing to start. \
            Missing: \(missing.joined(separator: ", ")). Set all of CF_ACCESS_TEAM, \
            CF_ACCESS_AUD and CF_ACCESS_OWNER_EMAIL, or use WEBTERM_PASSWORD_HASH \
            for password auth instead.
            """
        }
    }
}

/// Resolve the server's authentication mode from environment variables.
///
/// Fail-closed policy: if neither a non-empty `WEBTERM_PASSWORD_HASH` nor a
/// complete Cloudflare Access configuration is present, this throws instead of
/// falling back to a guessable default password. Password auth takes precedence
/// over Cloudflare Access when both are configured (mirrors historical
/// behaviour). `env` is injected so the logic is unit-testable without mutating
/// the real process environment.
func resolveAuth(from env: [String: String]) throws -> WebTermConfig.Auth {
    // Treat set-but-empty values as unset throughout — an empty hash can never
    // verify, and an empty CF var is not a usable configuration.
    func nonEmpty(_ key: String) -> String? {
        guard let value = env[key], !value.isEmpty else { return nil }
        return value
    }

    if let hash = nonEmpty("WEBTERM_PASSWORD_HASH") {
        return .password(hash: hash)
    }

    let team = nonEmpty("CF_ACCESS_TEAM")
    let aud = nonEmpty("CF_ACCESS_AUD")
    let email = nonEmpty("CF_ACCESS_OWNER_EMAIL")

    // Any Cloudflare variable present signals the operator intends Cloudflare
    // mode — require the complete set and report exactly what is missing.
    if team != nil || aud != nil || email != nil {
        var missing: [String] = []
        if team == nil { missing.append("CF_ACCESS_TEAM") }
        if aud == nil { missing.append("CF_ACCESS_AUD") }
        if email == nil { missing.append("CF_ACCESS_OWNER_EMAIL") }
        if let team, let aud, let email, missing.isEmpty {
            return .cloudflare(team: team, aud: aud, ownerEmail: email)
        }
        throw AuthConfigError.incompleteCloudflareConfig(missing: missing)
    }

    throw AuthConfigError.noAuthConfigured
}
