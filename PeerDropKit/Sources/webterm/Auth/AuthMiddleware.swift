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
        expectedHost: String,
        maxAge: TimeInterval = 12 * 3600
    ) -> AuthDecision {
        // Origin check: defence against cross-site WS / form posts.
        // Absent origin (e.g. curl) is allowed; a present but mismatching host is forbidden.
        if let origin, let url = URL(string: origin), let host = url.host, host != expectedHost {
            return .denyForbidden
        }
        switch mode {
        case .password(let secret):
            guard let cookie, SessionToken.verify(cookie, secret: secret, maxAge: maxAge) != nil else {
                return .denyUnauthorized
            }
            return .allow
        case .cloudflare:
            return cfJWTValidEmail != nil ? .allow : .denyUnauthorized
        }
    }
}

// MARK: - Hummingbird HTTP Middleware

/// Hummingbird 2.x middleware that enforces `AuthGate` on every request and, in password mode,
/// slides (refreshes) the session cookie on every authenticated response.
///
/// Cookie name: `"webterm-session"` (set by the login route after password verification).
/// Cloudflare mode: validates the `Cf-Access-Jwt-Assertion` JWT cryptographically via
/// `CfAccessVerifier` (signature + audience + email + expiry). The plaintext email header
/// `Cf-Access-Authenticated-User-Email` is NOT used — it is spoofable if the origin is ever
/// reachable without the Cloudflare proxy in front of it.
///
/// Sliding: on every successful authenticated request in password mode, the middleware calls
/// `SessionToken.slide(...)` and sets the resulting refreshed token as `Set-Cookie` on the
/// response, extending the idle window. If `slide` returns nil (absolute cap exceeded) the
/// response is returned as-is and the cookie will expire naturally.
public struct AuthMiddleware<Context: RequestContext>: RouterMiddleware {
    public let mode: AuthMode
    public let expectedHost: String
    /// Name of the session cookie set by the login endpoint.
    public let cookieName: String
    /// Present in cloudflare mode to cryptographically validate the Cf-Access-Jwt-Assertion JWT.
    /// Nil in password mode.
    public let cfVerifier: CfAccessVerifier?
    /// Idle TTL passed to `SessionToken.slide` on each successful request (password mode only).
    public let idleTTL: TimeInterval
    /// Absolute session cap passed to `SessionToken.verify` and `SessionToken.slide`.
    public let maxAge: TimeInterval

    private init(
        mode: AuthMode,
        expectedHost: String,
        cfVerifier: CfAccessVerifier?,
        cookieName: String,
        idleTTL: TimeInterval,
        maxAge: TimeInterval
    ) {
        self.mode = mode
        self.expectedHost = expectedHost
        self.cfVerifier = cfVerifier
        self.cookieName = cookieName
        self.idleTTL = idleTTL
        self.maxAge = maxAge
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
            do {
                cfEmail = try await verifier.verify(assertion)
            } catch {
                context.logger.notice("Cf-Access JWT rejected: \(error)")
            }
        }

        let origin = request.headers[.origin]

        let decision = AuthGate.decide(
            mode: mode,
            cookie: cookie,
            cfJWTValidEmail: cfEmail,
            origin: origin,
            expectedHost: expectedHost,
            maxAge: maxAge
        )

        switch decision {
        case .allow:
            var response = try await next(request, context)
            // In password mode, slide (refresh) the session cookie so active use
            // keeps the session alive within the idle window.
            if case .password = mode, let rawCookie = cookie {
                if let slid = SessionToken.slide(
                    rawCookie,
                    secret: modeSecret,
                    idleTTL: idleTTL,
                    maxAge: maxAge
                ) {
                    let isSecure = expectedHost != "localhost"
                    let refreshed = Cookie(
                        name: cookieName,
                        value: slid,
                        maxAge: Int(idleTTL),
                        path: "/",
                        secure: isSecure,
                        httpOnly: true,
                        sameSite: .strict
                    )
                    response.setCookie(refreshed)
                }
                // If slide returns nil (absolute cap hit), don't set a new cookie — let it expire.
            }
            return response
        case .denyUnauthorized:
            // F4: browsing to the bare / while logged out should land on the login form,
            // not a raw 401 page. Redirect GET / → /login only; all other gated paths
            // (API endpoints, WS upgrades, /logout) keep the existing 401 behaviour so
            // clients can detect auth failures programmatically.
            if request.method == .get && request.uri.path == "/" {
                return Response.redirect(to: "/login", type: .normal)
            }
            throw HTTPError(.unauthorized)
        case .denyForbidden:
            throw HTTPError(.forbidden)
        }
    }

    /// Extracts the raw secret bytes from the password mode case.
    private var modeSecret: Data {
        if case .password(let secret) = mode { return secret }
        return Data()
    }
}

// MARK: - Factory Initialisers

extension AuthMiddleware {
    /// Password mode: gate on the signed session cookie. No Cf-Access verifier.
    ///
    /// - Parameters:
    ///   - secret: HMAC-SHA256 secret for session cookie verification and sliding.
    ///   - expectedHost: Host checked against the `Origin` header.
    ///   - cookieName: Cookie name (default `"webterm-session"`).
    ///   - idleTTL: Idle window in seconds; extended on each authenticated request (default 1800 s).
    ///   - maxAge: Absolute session cap in seconds (default 43200 s).
    public static func password(
        secret: Data,
        expectedHost: String,
        cookieName: String = "webterm-session",
        idleTTL: TimeInterval = 30 * 60,
        maxAge: TimeInterval = 12 * 3600
    ) -> AuthMiddleware {
        AuthMiddleware(
            mode: .password(secret: secret),
            expectedHost: expectedHost,
            cfVerifier: nil,
            cookieName: cookieName,
            idleTTL: idleTTL,
            maxAge: maxAge
        )
    }

    /// Cloudflare mode: REQUIRES a CfAccessVerifier — you cannot build this mode without one.
    public static func cloudflare(
        verifier: CfAccessVerifier,
        expectedHost: String,
        cookieName: String = "webterm-session",
        idleTTL: TimeInterval = 30 * 60,
        maxAge: TimeInterval = 12 * 3600
    ) -> AuthMiddleware {
        AuthMiddleware(
            mode: .cloudflare,
            expectedHost: expectedHost,
            cfVerifier: verifier,
            cookieName: cookieName,
            idleTTL: idleTTL,
            maxAge: maxAge
        )
    }
}
