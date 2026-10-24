// RendezvousRoom — anonymous two-party blind relay (Project E).
//
// PRIVACY: this class never parses, stores or logs frame contents, never
// touches DO storage (no alarm either), and never calls console.*. Per-socket
// bookkeeping (last-frame time, optional session id) lives in the
// hibernation-safe socket attachment, not in storage.
//
// HONEST LIMITS (do not oversell in docs):
//   - Pings count as frames. Liveness/idle is a ONE-SIDED signal ("this socket
//     was heard from"), not proof the peer or user is present.
//   - Cloudflare platform analytics still know a DO named by the token was
//     invoked (objectId, timing, sizes) regardless of anything we do here.
//   - Control frames {"t":"joined"} / {"t":"left"} and the literal text "ping"
//     travel on the same channel as relayed app frames. They are HINTS: a
//     malicious peer can send the same bytes. Clients must wrap app frames in
//     their own envelope and must not trust control frames for security.
//
// The room name is the (secret) rendezvous token; sockets are connected here
// by the Worker front (rendezvousRoute.ts) after PoW validation.

export const RV_IDLE_MS = 2 * 60 * 60 * 1000;
/** A socket silent (no frame, no ping) for longer than this may be evicted by a joiner. */
export const RV_STALE_MS = 90_000;
export const RV_CLOSE_CODE = 1008;
export const RV_CLOSE_REASON = "denied";
/** Internal Worker->DO header carrying the optional session id. Never logged/forwarded. */
export const RV_SESSION_HEADER = "X-Rv-S";
const MAX_SOCKETS = 2;
const WS_OPEN = 1;

interface Att { last: number; s?: string; replaced?: boolean }

export class RendezvousRoom {
  ctx: DurableObjectState;
  /** Injectable clock (tests). */
  now: () => number = () => Date.now();

  constructor(ctx: DurableObjectState, _env: unknown) {
    this.ctx = ctx;
    this.ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  private att(ws: WebSocket): Att {
    try {
      const a = ws.deserializeAttachment() as Att | null;
      if (a && typeof a.last === "number") return a;
    } catch { /* closed */ }
    return { last: 0 };
  }

  /** Sockets that are actually open (CLOSING ones do not count as occupants). */
  private openSockets(): WebSocket[] {
    return this.ctx.getWebSockets().filter((s) => s.readyState === WS_OPEN);
  }

  /** Last time we heard from this socket: a real frame or an auto-answered ping. */
  private lastSeen(ws: WebSocket): number {
    const auto = this.ctx.getWebSocketAutoResponseTimestamp(ws)?.getTime() ?? 0;
    return Math.max(this.att(ws).last, auto);
  }

  /** Close a socket on purpose; tell its peer `left` exactly once. */
  private replace(ws: WebSocket): void {
    const a = this.att(ws);
    try { ws.serializeAttachment({ ...a, replaced: true }); } catch { /* closing */ }
    this.notifyLeft(ws);
    try { ws.close(RV_CLOSE_CODE, RV_CLOSE_REASON); } catch { /* already closed */ }
  }

  async fetch(request: Request): Promise<Response> {
    if (request.headers.get("Upgrade") !== "websocket") {
      return new Response(null, { status: 400 });
    }
    this.checkIdle();
    const sid = request.headers.get(RV_SESSION_HEADER) || undefined;

    // Instant takeover: same session id (client-generated, per token+run).
    if (sid) {
      for (const s of this.openSockets()) {
        if (this.att(s).s === sid) this.replace(s);
      }
    }
    // Full room: only a STALE socket may be evicted; a live one never is.
    const occupants = this.openSockets();
    if (occupants.length >= MAX_SOCKETS) {
      const t = this.now();
      const stale = occupants.find((s) => t - this.lastSeen(s) > RV_STALE_MS);
      if (!stale) return new Response(null, { status: 409 });
      this.replace(stale);
    }

    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    this.ctx.acceptWebSocket(server);
    const att: Att = { last: this.now() };
    if (sid) att.s = sid;
    server.serializeAttachment(att);
    const now = this.openSockets();
    if (now.length === MAX_SOCKETS) {
      for (const s of now) {
        try { s.send('{"t":"joined"}'); } catch { /* socket gone */ }
      }
    }
    return new Response(null, { status: 101, webSocket: client });
  }

  /** Record that a frame was heard from this socket. */
  touch(ws: WebSocket): void {
    try { ws.serializeAttachment({ ...this.att(ws), last: this.now() }); } catch { /* closing */ }
  }

  /** Close everything if nothing has been heard for RV_IDLE_MS. */
  checkIdle(): void {
    const sockets = this.openSockets();
    if (sockets.length === 0) return;
    const t = this.now();
    let last = 0;
    for (const s of sockets) last = Math.max(last, this.lastSeen(s));
    if (t - last >= RV_IDLE_MS) {
      for (const s of sockets) {
        try { s.close(RV_CLOSE_CODE, RV_CLOSE_REASON); } catch { /* already closed */ }
      }
    }
  }

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    this.checkIdle();
    this.touch(ws);
    for (const other of this.openSockets()) {
      if (other === ws) continue;
      try { other.send(message); } catch { /* peer gone */ }
    }
  }

  private notifyLeft(ws: WebSocket): void {
    for (const other of this.openSockets()) {
      if (other === ws) continue;
      try { other.send('{"t":"left"}'); } catch { /* peer gone */ }
    }
  }

  async webSocketClose(ws: WebSocket, _code: number, _reason: string, _wasClean: boolean): Promise<void> {
    if (!this.att(ws).replaced) this.notifyLeft(ws);
    try { ws.close(1000, ""); } catch { /* already closed */ }
  }

  async webSocketError(ws: WebSocket, _error: unknown): Promise<void> {
    if (!this.att(ws).replaced) this.notifyLeft(ws);
    try { ws.close(1011, ""); } catch { /* already closed */ }
  }
}
