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
/// Cookie name: `"wt_session"` (set by the login route after password verification).
/// Cloudflare Access JWT header: `"Cf-Access-Authenticated-User-Email"` (injected by the CF proxy
/// after it validates the JWT — we trust the header value here because the JWT itself was
/// already verified upstream by Cloudflare before the request reaches this server).
public struct AuthMiddleware<Context: RequestContext>: RouterMiddleware {
    public let mode: AuthMode
    public let expectedHost: String
    /// Name of the session cookie set by the login endpoint.
    public let cookieName: String

    public init(mode: AuthMode, expectedHost: String, cookieName: String = "wt_session") {
        self.mode = mode
        self.expectedHost = expectedHost
        self.cookieName = cookieName
    }

    public func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        let cookie = request.cookies[cookieName]?.value
        // swiftlint:disable:next force_unwrapping
        let cfEmail = request.headers[HTTPField.Name("Cf-Access-Authenticated-User-Email")!]
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
