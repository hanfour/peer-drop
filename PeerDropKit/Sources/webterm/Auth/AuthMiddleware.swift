import Foundation
import HTTPTypes
import Hummingbird

// MARK: - Pure Auth Policy (no Hummingbird dependency on types)

public enum AuthMode: Sendable {
    case password(secret: Data)
    case cloudflare
}

public enum AuthDecision: Equatable { case allow, denyUnauthorized, denyForbidden }

/// Pure auth policy — shared by the HTTP middleware and the WS upgrade gate.
/// No Hummingbird types here so the gate can be unit-tested without spinning up
/// an Application.
public enum AuthGate {
    public static func decide(
        mode: AuthMode,
        cookie: String?,
        cfJWTValidEmail: String?,
        origin: String?,
        expectedHost: String
    ) -> AuthDecision {
        // Origin check: defence against cross-site WS / form posts.
        // Absent origin (e.g. curl) is allowed; a present but mismatching host is forbidden.
        if let origin, let url = URL(string: origin), let host = url.host, host != expectedHost {
            return .denyForbidden
        }
        switch mode {
        case .password(let secret):
            guard let cookie, SessionToken.verify(cookie, secret: secret) != nil else {
                return .denyUnauthorized
            }
            return .allow
        case .cloudflare:
            return cfJWTValidEmail != nil ? .allow : .denyUnauthorized
        }
    }
}

// MARK: - Hummingbird HTTP Middleware

/// Hummingbird 2.x middleware that enforces `AuthGate` on every request.
///
/// Cookie name: `"webterm-session"` (set by the login route after password verification).
/// Cloudflare mode: validates the `Cf-Access-Jwt-Assertion` JWT cryptographically via
/// `CfAccessVerifier` (signature + audience + email + expiry). The plaintext email header
/// `Cf-Access-Authenticated-User-Email` is NOT used — it is spoofable if the origin is ever
/// reachable without the Cloudflare proxy in front of it.
public struct AuthMiddleware<Context: RequestContext>: RouterMiddleware {
    public let mode: AuthMode
    public let expectedHost: String
    /// Name of the session cookie set by the login endpoint.
    public let cookieName: String
    /// Present in cloudflare mode to cryptographically validate the Cf-Access-Jwt-Assertion JWT.
    /// Nil in password mode.
    public let cfVerifier: CfAccessVerifier?

    public init(
        mode: AuthMode,
        expectedHost: String,
        cookieName: String = "webterm-session",
        cfVerifier: CfAccessVerifier? = nil
    ) {
        self.mode = mode
        self.expectedHost = expectedHost
        self.cookieName = cookieName
        self.cfVerifier = cfVerifier
    }

    public func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        let cookie = request.cookies[cookieName]?.value

        // Validate the Cloudflare Access JWT cryptographically — never trust the plaintext email header.
        var cfEmail: String? = nil
        if case .cloudflare = mode, let verifier = cfVerifier,
           // swiftlint:disable:next force_unwrapping
           let assertion = request.headers[HTTPField.Name("Cf-Access-Jwt-Assertion")!] {
            cfEmail = try? await verifier.verify(assertion)
        }

        let origin = request.headers[.origin]

        let decision = AuthGate.decide(
            mode: mode,
            cookie: cookie,
            cfJWTValidEmail: cfEmail,
            origin: origin,
            expectedHost: expectedHost
        )

        switch decision {
        case .allow:
            return try await next(request, context)
        case .denyUnauthorized:
            throw HTTPError(.unauthorized)
        case .denyForbidden:
            throw HTTPError(.forbidden)
        }
    }
}
