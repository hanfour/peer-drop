# webterm — Design Spec

**Date:** 2026-06-20
**Status:** Approved (brainstorming) → ready for implementation plan
**Author:** Claude + hanfour
**Working name:** `webterm` (bikeable)

---

## 1. Summary

A self-hosted Swift web terminal. The owner runs one instance on their own
machine; from anywhere they open a browser, pass their own Cloudflare Zero Trust
(Access) perimeter, and reach a faithful terminal (xterm.js) attached to a
**persistent tmux session** on that machine — to launch Claude Code (or anything)
in a preset directory and peek in later to see what it did.

It reuses the PTY core from PeerDrop's `ProcessBridge` (extracted into a
`PeerDropPTY` library), wraps it around `tmux attach`, and exposes it over a
WebSocket served by a lightweight Swift web server (Hummingbird). The server
binds localhost only; the sole ingress is the owner's `cloudflared` tunnel.

## 2. Goals / Non-Goals

### Goals
- Reach a faithful terminal (full key passthrough — Ctrl-C, Shift+Tab for Claude
  Code's Edit/Plan toggle, arrows, etc.) from a browser.
- Persistent sessions that survive browser disconnect AND a webterm restart
  (tmux-backed), so a long-running Claude Code task keeps going and can be
  observed later.
- Launch from named preset commands (e.g. "Claude in ~/Projects/X"); a plain
  shell is always available.
- Multi-layer security so exposing it never leaves the machine open: localhost
  bind + Cloudflare Access perimeter + an app-level gate + WebSocket auth.
- Self-hostable single-tenant: each owner runs and configures their own.

### Non-Goals (this spec / MVP)
- Multi-tenant central service, user management, shared collaborative sessions.
- Surviving a true OS reboot with a process resumed mid-task (impossible without
  process checkpointing; the closest — auto-recreate preset sessions fresh on
  boot — is Phase 2).
- Mobile on-screen key bar, OAuth/third-party login, free-form command box — all
  Phase 2.

## 3. Key Decisions (locked during brainstorming)

| Decision | Choice |
|---|---|
| Greenfield vs existing | Greenfield; reuse only the PTY core |
| Deployment model | Self-hosted **single-tenant** (each owner runs their own) |
| Primary device | Both desktop + mobile, but **MVP = desktop passthrough**; mobile key bar Phase 2 |
| Server core | **A** — Swift server reusing the PTY core (not adopting ttyd) |
| Web framework | **Hummingbird** (lightweight, NIO-based, WebSocket) |
| Terminal frontend | **xterm.js** (industry-standard; not reinvented) |
| Session persistence | **tmux-backed** — survives webterm restart + all disconnects |
| Auth | **Dual-mode**, owner-configurable: `password` (hashed + session cookie, optional OAuth in P2) OR `cloudflare` (validate Cf-Access JWT). Defense-in-depth |
| Network | Bind **localhost only**; ingress only via the owner's `cloudflared` tunnel |
| Repo | In the `peer-drop` repo; `PeerDropPTY` shared library + a new `webterm` target |

## 4. Architecture

A single Swift executable the owner runs (ideally under launchd). Components:

| Component | Responsibility | New/Reused |
|---|---|---|
| **`PeerDropPTY`** (library) | PTY core extracted from `ProcessBridge`: `openpty`, spawn, master-fd read/write, cancel-handler fd close, restart-safety, **+ new raw mode (no ANSI strip / no idle-flush segmentation) + `resize(cols,rows)` via `ioctl(TIOCSWINSZ)`** | Reused + extended |
| **`TerminalSession`** | One tmux-attached PTY = one session. Broadcasts raw PTY output to all attached WS clients; fans in client input to the PTY; applies resize; keeps a small ring buffer only to bridge WS-reconnect gaps (tmux owns real scrollback) | New |
| **`SessionManager`** | sessionID → `TerminalSession`; create from preset (spawn detached tmux session, then attach); list running tmux sessions; reap | New |
| **`PresetStore`** | Loads presets from config (`id`, `name`, `command`, `cwd`, `env?`) + an always-available `$SHELL` preset | New |
| **`WebServer`** (Hummingbird) | Routes: `GET /` (terminal page, auth-gated), login routes, `WS /ws/:sessionId`, `GET/POST /api/sessions`, static assets | New |
| **`AuthMiddleware`** | Dual-mode gate (`password` session cookie OR `cloudflare` Cf-Access JWT validation); gates HTTP routes AND the WS upgrade; origin check; CSRF; login rate-limit | New |
| **Frontend** (static) | xterm.js terminal, auto-fit + resize emit, session picker (preset / reattach a running tmux session). Mobile key bar = Phase 2 | New |
| **Config** | Presets + auth mode + (P2 OAuth creds) + bind port + Cloudflare team domain/aud | New |

**Reuse reality:** `PeerDropPTY` is the genuine reuse of `ProcessBridge` (PTY
core + restart-safety). It depends on the `ProcessBridge` introduced in PR #115;
Phase 0 extracts the PTY plumbing into a library both `peerdrop-cli` and
`webterm` import. Everything else is new.

## 5. Session Model & Data Flow (tmux-backed)

### 5.1 Persistence via tmux
Each session is a named tmux session (`webterm-<id>`). Launch from a preset:
`tmux new-session -d -s webterm-<id> -c <cwd> '<command>'` (detached, starts
running immediately). The webterm PTY wraps **`tmux attach -t webterm-<id>`** —
the browser's PTY is a tmux client. Browser disconnects → detach → the tmux
session keeps running. tmux owns:
- **Persistence:** survives webterm restart / crash / update, and all
  disconnects (tmux server is a separate daemon).
- **Scrollback + reattach:** `tmux attach` redraws the current screen, so
  reattach "just works"; the webterm ring buffer only bridges the brief
  WS-reconnect gap.
- **Multi-client mirror:** multiple clients attaching the same tmux session get
  native mirroring (synced content + shared sizing).

`remain-on-exit on` keeps an exited command's pane visible for review.

**Reboot boundary (honest):** a true OS reboot kills the tmux server and its
processes — no mechanism can resume a mid-task process across a power cycle.
"Survives reboot" is achievable only as *auto-recreate preset sessions fresh on
boot* (Phase 2, via launchd). MVP persistence = across webterm restart + all
disconnects.

### 5.2 Data flow (raw, byte-faithful)
```
Browser xterm ──(WS binary)──▶ TerminalSession.write(bytes) → PTY master (tmux client stdin)
       ▲                                   │ PTY master read → raw bytes
       │                                   ▼
 xterm.write(bytes) ◀──(WS binary)── broadcast to all attached clients (+ ring buffer)
```
- **Input:** xterm `onData` → WS → PTY master write. **All keys pass through**
  (Ctrl-C, Shift+Tab, arrows, Esc) — this is the hotkey/mode-switch requirement.
- **Output:** PTY master raw bytes → broadcast to all WS clients of the session.
- **Resize:** xterm `onResize(cols,rows)` → WS control frame → `ioctl(master,
  TIOCSWINSZ)` → propagates to the tmux client → tmux resizes the pane.
- **Reattach:** new WS to `:sessionId` → flush ring buffer → live stream; tmux
  redraws.

### 5.3 WebSocket control protocol
Binary frames; first byte is a tag:
- `0x00` = data (raw terminal bytes, both directions)
- `0x01` = resize (payload: `cols` `rows` as two UInt16)
- `0x02` = ping/keepalive
Low-latency, suited to interactive streaming.

## 6. Auth & Security (defense-in-depth)

- **Layer 0 — localhost-only + cloudflared.** Server binds `127.0.0.1:<port>`;
  no open inbound port on the machine. Sole ingress = the owner's outbound
  `cloudflared` tunnel. Eliminates port-scan / direct-hit attacks.
- **Layer 1 — Cloudflare Zero Trust (Access).** Owner routes a hostname →
  `localhost:<port>` and adds an Access policy allowing only their identity.
  Unauthorized requests never reach the tunnel. Passing requests carry a
  Cloudflare-signed `Cf-Access-Jwt-Assertion`.
- **Layer 2 — App gate (dual-mode, owner-configurable):**
  - `password`: app requires login; owner credential stored **hashed**
    (argon2/bcrypt); login issues a **signed session cookie** (httpOnly, Secure,
    SameSite=Strict, expiry). Works standalone (no Cloudflare needed). OAuth
    (GitHub/Google) is Phase 2.
  - `cloudflare`: no app password; every request **cryptographically validates
    the Cf-Access JWT** — verify signature against the team's public keys
    (`https://<team>.cloudflareaccess.com/cdn-cgi/access/certs`, cached), check
    `aud`, expiry, and email == owner. *Validates the JWT, not a spoofable
    header.* Fail closed if keys can't be fetched.
- **Layer 3 — WebSocket auth.** The WS upgrade is gated by the same middleware
  (cookie / Cf-Access JWT) — no unauthenticated raw WS to the terminal.
- **Layer 4/5 — Hardening.** WS `Origin` check; login CSRF token; login
  rate-limit + backoff; session expiry + idle timeout + logout; TLS terminated
  at Cloudflare's edge (cookies Secure); the process runs as the owner's
  non-root user.

**Build vs configure:** we build the localhost server, dual-mode AuthMiddleware,
session/WS/CSRF/rate-limit, config schema, launchd + cloudflared templates, and
setup docs. The owner configures their Cloudflare account, tunnel, Access policy,
(P2) OAuth creds, and (password mode) the password.

## 7. Presets

Config (`~/.config/webterm/config.toml`) lists `[[preset]]` entries (`id`,
`name`, `command`, `cwd`, `env?`) plus an always-available plain `$SHELL`. Each
preset maps to a tmux session. The UI session picker lists presets + currently
running tmux sessions (reattach). **MVP: presets + shell only — no free-form
command box in the web UI** (bounds blast radius if a session token ever leaks);
"open anything" is satisfied because a shell preset can run anything and any
preset can be any command. Free-form box = Phase 2.

## 8. Error Handling

| Situation | Behavior |
|---|---|
| WS drops | Session persists (tmux); client auto-reconnects (exponential backoff) + tmux redraws |
| Wrapped command exits | tmux `remain-on-exit on` keeps the pane; UI shows "ended" + offer to relaunch |
| tmux not installed | Clear startup error + install hint |
| Bad config / port in use | Fail fast with a clear message |
| Auth failure | 401 + login (password) / 403 (cloudflare) |
| Cf-Access keys unfetchable (cloudflare mode) | **Fail closed** (deny) + log |
| Output flood | Chunk WS frames; tmux paces output |

## 9. Testing

- **`PeerDropPTY`:** extend `ProcessBridge` tests — raw byte round-trip (no ANSI
  strip), `resize` reflected in the child (`tput cols`/`stty size`), exit/restart.
- **tmux bridge / `TerminalSession`:** integration against a real throwaway tmux
  session — create/attach/write/read, detach-persists, reattach-redraws,
  multi-client; drop+reattach proving the session survives a simulated webterm
  restart.
- **`AuthMiddleware`:** unit — password verify + cookie sign/verify/expiry;
  Cf-Access JWT validation (self-signed test key: valid / invalid-sig / expired /
  wrong-aud / wrong-email); WS-upgrade gating; origin check; rate-limit.
- **`WebServer`:** integration — Hummingbird on a port: unauth `/` → 401/redirect,
  login → cookie → 200, `/api/sessions` create/list, WS with/without auth.
- **E2E (manual, the real proof):** run webterm + a `claude` preset; browser
  type/resize; close+reopen (tmux reattach); restart webterm (session survives);
  all behind a real `cloudflared` tunnel + Access policy.

## 10. Phasing

- **Phase 0:** extract `PeerDropPTY` library (raw mode + resize) from
  `ProcessBridge`; tests. (Depends on PR #115's ProcessBridge.)
- **Phase 1 (MVP):** Hummingbird (localhost) + xterm.js desktop terminal +
  tmux-backed persistent sessions + presets/shell + **both auth modes**
  (password: hashed + cookie + WS gate + CSRF + rate-limit; cloudflare: Cf-Access
  JWT validation) + WS protocol (data/resize/ping) + reattach + launchd +
  cloudflared templates + setup docs. Desktop passthrough.
- **Phase 2:** OAuth (GitHub/Google) + mobile on-screen key bar + boot
  auto-recreate of preset sessions + free-form command box.

## 11. Open Questions / Risks

- **Hummingbird WebSocket maturity:** confirm Hummingbird 2.x's WS support
  (binary frames, upgrade middleware, backpressure) fits; fall back to
  Vapor/raw-NIO if it doesn't. De-risk early in Phase 1.
- **tmux resize semantics:** with multiple clients of different sizes, tmux uses
  the smallest (or `window-size` setting); pick a `window-size`/`aggressive-resize`
  config that gives the active browser a clean size. Verify in the tmux-bridge
  task.
- **PeerDropPTY extraction vs PR #115:** Phase 0 assumes ProcessBridge has
  landed; if #115 is still open, branch `feat/webterm` off it (current plan) and
  rebase onto main after merge.
- **Cf-Access JWT validation correctness:** JWKS fetch/caching, `aud`/`iss`
  checks, clock skew — get the validation exactly right (security-critical);
  cover with the unit matrix in §9.
