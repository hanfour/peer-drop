import Foundation
import Hummingbird
import HummingbirdWebSocket

// MARK: - Public entry point

/// Build and return a Hummingbird `Application` wired with all WebTerm routes.
///
/// Routes:
///   GET  /         → 200 (auth-gated; returns simple status JSON)
///   GET  /login    → 200 (login form HTML; exempt from auth)
///   POST /login    → 303 redirect + session cookie on success, 401 on bad password
///   GET  /api/sessions  → 200 JSON list of running session IDs (auth-gated)
///   POST /api/sessions  → 200 JSON {id} for a new/reattached session (auth-gated)
///   WS   /ws/:sessionId → WebSocket terminal (auth-gated via AuthMiddleware on upgrade request)
///
/// The WS endpoint auth gate reads the `webterm-session` cookie from the upgrade request's
/// `Cookie` header and validates it with `AuthGate.decide` before allowing the upgrade.
public func buildApplication(_ cfg: WebTermConfig) throws -> some ApplicationProtocol {
    // Shared session manager
    let sessionManager = SessionManager(presets: PresetStore(presets: cfg.presets))

    // MARK: HTTP Router

    let router = Router(context: BasicRequestContext.self)

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
        let cookie = Cookie(
            name: "webterm-session",
            value: token,
            maxAge: 86400,
            path: "/",
            httpOnly: true
        )
        var response = Response.redirect(to: "/", type: .normal)
        response.setCookie(cookie)
        return response
    }

    // Apply auth middleware — all routes added AFTER this call require authentication
    router.add(middleware: makeAuthMiddleware(cfg: cfg) as AuthMiddleware<BasicRequestContext>)

    // GET / — status page (auth-gated)
    router.get("/") { _, _ -> Response in
        Response(
            status: .ok,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(string: #"{"status":"ok"}"#))
        )
    }

    // GET /api/sessions — list running session IDs (auth-gated)
    router.get("/api/sessions") { _, _ -> Response in
        let ids = sessionManager.runningSessionIDs()
        let json = "[" + ids.map { #""\#($0)""# }.joined(separator: ",") + "]"
        return Response(
            status: .ok,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(string: json))
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
    wsRouter.add(middleware: makeAuthMiddleware(cfg: cfg) as AuthMiddleware<BasicWebSocketRequestContext>)

    wsRouter.ws("/ws/:sessionId",
        shouldUpgrade: { _, _ -> RouterShouldUpgrade in
            // Auth is enforced by the AuthMiddleware above; just approve the upgrade.
            return .upgrade([:])
        },
        onUpgrade: { inbound, outbound, context in
            // The sessionId in the URL is the raw preset ID (e.g. "shell").
            // The tmux session was created with the prefixed name.
            let sessionId = context.requestContext.parameters.get("sessionId") ?? ""

            // Validate sessionId: only alphanumeric, underscore, hyphen
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
            guard !sessionId.isEmpty, sessionId.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
                // Invalid sessionId — close WS immediately
                return
            }

            // If the client passes the full tmux name (webterm-shell) we use it directly;
            // if just the preset id (shell) we prefix it.
            let tmuxID: String
            if sessionId.hasPrefix(TmuxControl.prefix) {
                tmuxID = sessionId
            } else {
                tmuxID = TmuxControl.prefix + sessionId
            }

            // Find or create the TerminalSession
            guard TmuxControl.exists(tmuxID) else {
                // Session doesn't exist — close WS immediately
                return
            }

            // Attach to session
            let session = TerminalSession(id: tmuxID)
            let clientID = session.addClient { data in
                let frame = WSFrame.data(data).encoded()
                Task { try? await outbound.write(.binary(ByteBuffer(bytes: frame))) }
            }
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
private func makeAuthMiddleware<Context: RequestContext>(cfg: WebTermConfig) -> AuthMiddleware<Context> {
    switch cfg.auth {
    case .password:
        return AuthMiddleware.password(
            secret: cfg.sessionSecret,
            expectedHost: cfg.expectedHost
        )
    case .cloudflare(_, let aud, let ownerEmail):
        // Note: for Cloudflare mode, CfAccessVerifier needs a JWTKeyCollection loaded from
        // the team JWKS. That async setup happens in the composition root (main.swift).
        // For now, fall back to a minimal verifier with no keys (all CF requests will be
        // denied until keys are loaded). This is intentional — the composition root should
        // call `buildApplication` only after the verifier is ready.
        let verifier = CfAccessVerifier(audience: aud, ownerEmail: ownerEmail, keys: .init())
        return AuthMiddleware.cloudflare(
            verifier: verifier,
            expectedHost: cfg.expectedHost
        )
    }
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

