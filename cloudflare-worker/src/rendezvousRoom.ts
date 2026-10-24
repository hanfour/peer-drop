// RendezvousRoom — anonymous two-party blind relay (Project E).
//
// PRIVACY: this class never parses, stores or logs frame contents, never
// touches DO storage, and never calls console.*. Per-socket idle timestamps
// live in the hibernation-safe socket attachment (not storage).
//
// The room name is the (secret) rendezvous token; sockets are connected here
// by the Worker front (rendezvousRoute.ts) after PoW validation.

export const RV_IDLE_MS = 2 * 60 * 60 * 1000;
export const RV_CLOSE_CODE = 1008;
export const RV_CLOSE_REASON = "denied";
const MAX_SOCKETS = 2;

export class RendezvousRoom {
  ctx: DurableObjectState;
  /** Injectable clock (tests). */
  now: () => number = () => Date.now();

  constructor(ctx: DurableObjectState, _env: unknown) {
    this.ctx = ctx;
    this.ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  async fetch(request: Request): Promise<Response> {
    if (request.headers.get("Upgrade") !== "websocket") {
      return new Response(null, { status: 400 });
    }
    this.checkIdle();
    // A third socket is refused outright. Never evict an existing one.
    if (this.ctx.getWebSockets().length >= MAX_SOCKETS) {
      return new Response(null, { status: 409 });
    }
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    this.ctx.acceptWebSocket(server);
    server.serializeAttachment({ last: this.now() });
    if (this.ctx.getWebSockets().length === MAX_SOCKETS) {
      for (const s of this.ctx.getWebSockets()) {
        try { s.send('{"t":"joined"}'); } catch { /* socket gone */ }
      }
    }
    return new Response(null, { status: 101, webSocket: client });
  }

  /** Record activity on every socket (idle cap is per room). */
  touch(_ws?: WebSocket): void {
    const t = this.now();
    for (const s of this.ctx.getWebSockets()) {
      try { s.serializeAttachment({ last: t }); } catch { /* closing */ }
    }
  }

  /** Close everything if no frame has arrived for RV_IDLE_MS. */
  checkIdle(): void {
    const sockets = this.ctx.getWebSockets();
    if (sockets.length === 0) return;
    const t = this.now();
    let last = 0;
    for (const s of sockets) {
      const a = s.deserializeAttachment() as { last?: number } | null;
      if (a && typeof a.last === "number" && a.last > last) last = a.last;
    }
    if (t - last >= RV_IDLE_MS) {
      for (const s of sockets) {
        try { s.close(RV_CLOSE_CODE, RV_CLOSE_REASON); } catch { /* already closed */ }
      }
    }
  }

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    this.checkIdle();
    this.touch(ws);
    for (const other of this.ctx.getWebSockets()) {
      if (other === ws) continue;
      try { other.send(message); } catch { /* peer gone */ }
    }
  }

  private notifyLeft(ws: WebSocket): void {
    for (const other of this.ctx.getWebSockets()) {
      if (other === ws) continue;
      try { other.send('{"t":"left"}'); } catch { /* peer gone */ }
    }
  }

  async webSocketClose(ws: WebSocket, _code: number, _reason: string, _wasClean: boolean): Promise<void> {
    this.notifyLeft(ws);
    try { ws.close(1000, ""); } catch { /* already closed */ }
  }

  async webSocketError(ws: WebSocket, _error: unknown): Promise<void> {
    this.notifyLeft(ws);
    try { ws.close(1011, ""); } catch { /* already closed */ }
  }
}
