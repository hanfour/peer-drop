import Foundation

/// Top-level configuration for the WebTerm server.
public struct WebTermConfig: Sendable {
    /// Authentication mode for the server.
    public enum Auth: Sendable {
        /// Password-based authentication. `hash` is a PBKDF2 hash produced by `PasswordHash.make(_:)`.
        case password(hash: String)
        /// Cloudflare Access authentication.
        case cloudflare(team: String, aud: String, ownerEmail: String)
    }

    /// TCP port to bind on. Use 0 to let the OS assign a free port (useful in tests).
    public var port: Int
    /// Expected hostname checked against the `Origin` header — requests from a different origin host
    /// are rejected with 403 (CSRF / DNS-rebinding defence). Set to your public hostname in production
    /// (e.g. `term.yourdomain.com`). Defaults to `"localhost"` for local development.
    public var expectedHost: String
    /// Authentication mode.
    public var auth: Auth
    /// 32-byte random secret used to sign session cookies with HMAC-SHA256.
    public var sessionSecret: Data
    /// Terminal presets made available via `/api/sessions`.
    public var presets: [Preset]

    public init(
        port: Int,
        expectedHost: String,
        auth: Auth,
        sessionSecret: Data,
        presets: [Preset]
    ) {
        self.port = port
        self.expectedHost = expectedHost
        self.auth = auth
        self.sessionSecret = sessionSecret
        self.presets = presets
    }

    /// Convenience factory for tests: password auth, random secret, port 0, empty presets.
    public static func test(password: String) -> WebTermConfig {
        WebTermConfig(
            port: 0,
            expectedHost: "localhost",
            auth: .password(hash: PasswordHash.make(password)),
            sessionSecret: Data((0..<32).map { _ in UInt8.random(in: 0...255) }),
            presets: []
        )
    }
}
