import Foundation
import Hummingbird
import HummingbirdWebSocket
import JWTKit

// MARK: - Public entry point

/// Build and return a Hummingbird `Application` wired with all WebTerm routes.
///
/// Routes:
///   GET  /         → 200 (auth-gated; serves index.html terminal page)
///   GET  /login    → 200 (login form HTML; exempt from auth)
///   POST /login    → 303 redirect + session cookie on success, 401 on bad password
///   GET  /api/sessions  → 200 JSON {presets:[{id,name,running}]} (auth-gated)
///   POST /api/sessions  → 200 JSON {id} for a new/reattached session (auth-gated)
///   WS   /ws/:sessionId → WebSocket terminal (auth-gated via AuthMiddleware on upgrade request)
///
/// The WS endpoint auth gate reads the `webterm-session` cookie from the upgrade request's
/// `Cookie` header and validates it with `AuthGate.decide` before allowing the upgrade.
/// Build and return a Hummingbird `Application` wired with all WebTerm routes.
///
/// - Parameters:
///   - cfg: The WebTerm configuration (auth mode, port, host, presets).
///   - cfVerifier: An optional pre-built `CfAccessVerifier` whose `JWTKeyCollection`
///     was populated by fetching the team JWKS. Pass this when `cfg.auth` is
///     `.cloudflare(...)` so that JWT verification actually works. When `nil`
///     in cloudflare mode the middleware falls back to an empty key collection
///     (fail-closed: every request is denied with a JWT verification error).
///     Has no effect in password mode.
///   - autostartPresets: When true, tmux sessions for all presets with `autostart == true`
///     are created immediately after the `SessionManager` is built. Failures are logged
///     to stderr and skipped — one bad preset cannot block server startup.
///     Defaults to `false` so that test callers using `buildApplication(cfg)` do not
///     accidentally spawn tmux processes.
public func buildApplication(_ cfg: WebTermConfig, cfVerifier: CfAccessVerifier? = nil,
                             autostartPresets: Bool = false) throws -> some ApplicationProtocol {
    // Shared session manager
    let sessionManager = SessionManager(presets: PresetStore(presets: cfg.presets))

    // Boot auto-recreate: create tmux sessions for presets with autostart == true.
    // Idempotent (TmuxControl.createIfNeeded is a no-op when the session already exists).
    // Failure-tolerant: a single bad preset must not prevent the server from starting.
    if autostartPresets {
        for p in cfg.presets where p.autostart {
            do {
                _ = try sessionManager.openSession(presetID: p.id)
            } catch {
                fputs("webterm: WARNING \u{2014} autostart preset '\(p.id)' failed: \(error)\n", stderr)
            }
        }
    }

    // MARK: HTTP Router

    let router = Router(context: BasicRequestContext.self)

    // Public static assets — registered BEFORE auth middleware so the browser
    // can load JS/CSS without a session cookie. These files contain no secrets.
    router.get("/app.js") { _, _ -> Response in
        staticFileResponse(named: "app", extension: "js", subdirectory: "Resources", contentType: "text/javascript; charset=utf-8")
    }
    router.get("/vendor/xterm.js") { _, _ -> Response in
        staticFileResponse(named: "xterm", extension: "js", subdirectory: "Resources/vendor", contentType: "text/javascript; charset=utf-8")
    }
    router.get("/vendor/xterm.css") { _, _ -> Response in
        staticFileResponse(named: "xterm", extension: "css", subdirectory: "Resources/vendor", contentType: "text/css; charset=utf-8")
    }
    router.get("/vendor/xterm-addon-fit.js") { _, _ -> Response in
        staticFileResponse(named: "xterm-addon-fit", extension: "js", subdirectory: "Resources/vendor", contentType: "text/javascript; charset=utf-8")
    }

    // /login routes — exempt from auth middleware (added BEFORE auth middleware is applied)
    router.get("/login") { _, _ -> Response in
        let html = loginPageHTML()
        var response = Response(
            status: .ok,
            headers: [.contentType: "text/html; charset=utf-8"],
            body: .init(byteBuffer: ByteBuffer(string: html))
        )
        _ = response  // suppress mutation warning
        return response
    }

    router.post("/login") { request, _ -> Response in
        // Parse application/x-www-form-urlencoded body
        let body = try await request.body.collect(upTo: 65_536)
        let bodyString = String(buffer: body)
        let params = parseFormURLEncoded(bodyString)
        let password = params["password"] ?? ""

        // Validate password against stored hash
        let isValid: Bool
        if case .password(let hash) = cfg.auth {
            isValid = PasswordHash.verify(password, against: hash)
        } else {
            // Cloudflare mode: password login not applicable
            isValid = false
        }

        guard isValid else {
            throw HTTPError(.unauthorized, message: "Invalid password")
        }

        // Issue a signed session cookie (24-hour TTL)
        let token = SessionToken.issue(subject: "owner", ttl: 86_400, secret: cfg.sessionSecret)
        // SameSite=Strict: mitigates CSRF / cross-origin WS attacks on all browsers.
        // Secure: added when not serving localhost (local dev works over plain HTTP).
        let isSecure = cfg.expectedHost != "localhost"
        let cookie = Cookie(
            name: "webterm-session",
            value: token,
            maxAge: 86400,
            path: "/",
            secure: isSecure,
            httpOnly: true,
            sameSite: .strict
        )
        var response = Response.redirect(to: "/", type: .normal)
        response.setCookie(cookie)
        return response
    }

    // Apply auth middleware — all routes added AFTER this call require authentication
    router.add(middleware: makeAuthMiddleware(cfg: cfg, cfVerifier: cfVerifier) as AuthMiddleware<BasicRequestContext>)

    // GET / — terminal page (auth-gated); serves index.html from bundle
    router.get("/") { _, _ -> Response in
        staticFileResponse(named: "index", extension: "html", subdirectory: "Resources", contentType: "text/html; charset=utf-8")
    }

    // GET /api/sessions — list presets with running status (auth-gated)
    router.get("/api/sessions") { _, _ -> Response in
        struct PresetInfo: Codable { let id: String; let name: String; let running: Bool }
        struct SessionsResponse: Codable { let presets: [PresetInfo] }
        let running = Set(sessionManager.runningSessionIDs())
        let infos = sessionManager.allPresets.map { p in
            PresetInfo(id: p.id, name: p.name, running: running.contains(TmuxControl.prefix + p.id))
        }
        let data = try JSONEncoder().encode(SessionsResponse(presets: infos))
        return Response(
            status: .ok,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(bytes: data))
        )
    }

    // POST /api/sessions — open or reattach a session (auth-gated)
    router.post("/api/sessions") { request, _ -> Response in
        let body = try await request.body.collect(upTo: 65_536)
        let bodyString = String(buffer: body)
        let params = parseFormURLEncoded(bodyString)
        let presetID = params["presetId"] ?? "shell"

        // Validate presetID: only alphanumeric, underscore, hyphen
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        guard !presetID.isEmpty, presetID.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw HTTPError(.badRequest, message: "Invalid preset ID")
        }

        _ = try sessionManager.openSession(presetID: presetID)
        // Return the tmux session ID (prefixed) so the client can connect via WS /ws/<id>
        let tmuxID = TmuxControl.prefix + presetID

        // JSON-encode the response
        struct SessionResponse: Codable { let id: String }
        let data = try JSONEncoder().encode(SessionResponse(id: tmuxID))
        return Response(
            status: .ok,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(bytes: data))
        )
    }

    // MARK: WebSocket Router (auth-gated via AuthMiddleware on upgrade request)

    let wsRouter = Router(context: BasicWebSocketRequestContext.self)

    // Apply the same AuthMiddleware to the WS router.
    // Hummingbird runs the wsRouter middleware chain on the HTTP upgrade
    // request BEFORE the WebSocket handshake, so the async CF JWT verify
    // (cloudflare mode) and the cookie check (password mode) both run here.
    // A failed auth throws HTTPError(.unauthorized) and the upgrade is denied.
    wsRouter.add(middleware: makeAuthMiddleware(cfg: cfg, cfVerifier: cfVerifier) as AuthMiddleware<BasicWebSocketRequestContext>)

    wsRouter.ws("/ws/:sessionId",
        shouldUpgrade: { _, _ -> RouterShouldUpgrade in
            // Auth is enforced by the AuthMiddleware above; just approve the upgrade.
            return .upgrade([:])
        },
        onUpgrade: { inbound, outbound, context in
            // The sessionId in the URL is the raw preset ID (e.g. "shell").
            let sessionId = context.requestContext.parameters.get("sessionId") ?? ""

            // Validate sessionId: only alphanumeric, underscore, hyphen
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
            guard !sessionId.isEmpty, sessionId.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
                // Invalid sessionId — reject unknown preset IDs and close WS immediately
                return
            }

            // Create-or-attach via SessionManager.
            // - openSession(presetID:) calls TmuxControl.createIfNeeded internally,
            //   so on a FRESH server this will spawn the tmux session before connecting.
            // - SessionManager caches TerminalSession by tmux id, so multiple concurrent
            //   WS connections (browser tabs) share one TerminalSession object.
            guard let session = try? sessionManager.openSession(presetID: sessionId) else {
                // Unknown preset id (not configured) — reject
                return
            }

            let clientID = session.addClient { data in
                let frame = WSFrame.data(data).encoded()
                Task { try? await outbound.write(.binary(ByteBuffer(bytes: frame))) }
            }
            // start() is idempotent: first call attaches a PTY, subsequent calls are no-ops.
            session.start()

            defer {
                session.removeClient(clientID)
                session.detach()
            }

            // Fan-in: relay inbound WS frames to the PTY
            for try await msg in inbound.messages(maxSize: 1 << 20) {
                if case .binary(var buffer) = msg,
                   let bytes = buffer.readBytes(length: buffer.readableBytes) {
                    let data = Data(bytes)
                    if let frame = WSFrame.decode(data) {
                        switch frame {
                        case .data(let d):
                            session.write(d)
                        case .resize(let cols, let rows):
                            session.resize(cols: cols, rows: rows)
                        case .ping:
                            try await outbound.write(.binary(ByteBuffer(bytes: WSFrame.ping.encoded())))
                        }
                    }
                }
            }
        }
    )

    // MARK: Application

    let app = Application(
        router: router,
        server: .http1WebSocketUpgrade(webSocketRouter: wsRouter),
        configuration: ApplicationConfiguration(
            address: .hostname("127.0.0.1", port: cfg.port)
        )
    )
    return app
}

// MARK: - Helpers

/// Build the `AuthMiddleware` appropriate for the config's auth mode.
/// Generic over `Context` so the same factory works for both the HTTP router
/// (`BasicRequestContext`) and the WS router (`BasicWebSocketRequestContext`).
///
/// - Parameters:
///   - cfg: The WebTerm configuration.
///   - cfVerifier: A pre-built `CfAccessVerifier` whose keys were loaded from the
///     team JWKS. If `nil` in cloudflare mode, falls back to an empty-key verifier
///     (fail-closed: every JWT verification will throw).
private func makeAuthMiddleware<Context: RequestContext>(
    cfg: WebTermConfig,
    cfVerifier: CfAccessVerifier? = nil
) -> AuthMiddleware<Context> {
    switch cfg.auth {
    case .password:
        return AuthMiddleware.password(
            secret: cfg.sessionSecret,
            expectedHost: cfg.expectedHost
        )
    case .cloudflare(_, let aud, let ownerEmail):
        // Use the injected verifier (with real JWKS keys) when available.
        // Fall back to an empty-key verifier so the behaviour is fail-closed:
        // all CF requests are denied rather than accidentally allowed.
        let verifier = cfVerifier ?? CfAccessVerifier(
            audience: aud,
            ownerEmail: ownerEmail,
            keys: JWTKeyCollection()
        )
        return AuthMiddleware.cloudflare(
            verifier: verifier,
            expectedHost: cfg.expectedHost
        )
    }
}

/// Read a resource file from Bundle.module and return an HTTP Response with the given
/// content-type. Returns 404 if the file cannot be found in the bundle.
///
/// SwiftPM's `.copy("Resources")` preserves the directory tree, so resource files live at
/// `Resources/<name>.<ext>` or `Resources/vendor/<name>.<ext>` inside the module bundle.
private func staticFileResponse(
    named name: String,
    extension ext: String,
    subdirectory: String,
    contentType: String
) -> Response {
    guard let url = Bundle.module.url(
        forResource: name,
        withExtension: ext,
        subdirectory: subdirectory
    ),
    let data = try? Data(contentsOf: url) else {
        return Response(
            status: .notFound,
            headers: [.contentType: "text/plain"],
            body: .init(byteBuffer: ByteBuffer(string: "Not found"))
        )
    }
    return Response(
        status: .ok,
        headers: [.contentType: contentType],
        body: .init(byteBuffer: ByteBuffer(bytes: data))
    )
}

/// Minimal `application/x-www-form-urlencoded` parser.
private func parseFormURLEncoded(_ body: String) -> [String: String] {
    var result: [String: String] = [:]
    for pair in body.split(separator: "&") {
        let kv = pair.split(separator: "=", maxSplits: 1)
        guard kv.count == 2 else { continue }
        let key = kv[0].removingPercentEncoding ?? String(kv[0])
        let value = kv[1].replacingOccurrences(of: "+", with: " ")
            .removingPercentEncoding ?? String(kv[1])
        result[key] = value
    }
    return result
}

/// Simple HTML login form.
private func loginPageHTML() -> String {
    """
    <!DOCTYPE html>
    <html>
    <head><title>WebTerm Login</title></head>
    <body>
      <h1>WebTerm</h1>
      <form method="post" action="/login">
        <label>Password: <input type="password" name="password" autofocus></label>
        <button type="submit">Login</button>
      </form>
    </body>
    </html>
    """
}

