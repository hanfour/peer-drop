# WebTerm — Self-Hosted Setup Guide

WebTerm is a single-tenant web terminal for PeerDrop's owner. It binds exclusively to
`127.0.0.1`, so the only way to reach it from outside is through a Cloudflare Tunnel +
Zero Trust Access policy. All sessions are backed by `tmux` and persist across browser
disconnects.

---

## Security model

```
Browser
  ↓  HTTPS
Cloudflare Access  ← perimeter gate (email / identity provider policy)
  ↓  encrypted tunnel (cloudflared)
127.0.0.1:7681 (webterm)
  ↓  app auth gate (AuthMiddleware)
     password mode  → PBKDF2 cookie check (constant-time)
     cloudflare mode → Cf-Access-JWT-Assertion header verify (RS256, fail-closed)
  ↓  WS upgrade also passes through AuthMiddleware
tmux session / PTY
```

Defense layers in depth:
1. **Localhost bind** — `webterm` listens on `127.0.0.1` only; no direct external
   exposure regardless of firewall state.
2. **Cloudflare Access perimeter** — blocks all unauthenticated requests at Cloudflare's
   edge before they reach the tunnel.
3. **App auth gate** — every HTTP route and every WS upgrade is checked by
   `AuthMiddleware`. A valid signed `webterm-session` cookie (HMAC-SHA256) is required.
4. **Origin check** — When a browser sends an `Origin` header (all cross-origin requests
   and WS upgrades), `AuthMiddleware` compares the `Origin` host against `WEBTERM_HOST`
   and returns 403 if they do not match (CSRF / DNS-rebinding defence). Requests without
   an `Origin` header (e.g. direct `curl`) are allowed through — they are already blocked
   by Cloudflare Access and the password/JWT layer above. **You must set `WEBTERM_HOST` to
   your real public hostname** (e.g. `term.yourdomain.com`) in production; the default
   `localhost` is for local development only.

---

## Prerequisites

macOS 13+, Homebrew.

```bash
brew install tmux cloudflared
```

Also needed: an Apple Developer account for code-signing is not required to _run_ the
binary locally, but the webterm binary must be built from the repo.

---

## Step 1 — Build the webterm binary

```bash
cd /path/to/peer-drop/PeerDropKit
swift build -c release --product webterm
```

The binary lands at:

```
PeerDropKit/.build/release/webterm
```

Build time is ~60–120 s on a cold build. Subsequent incremental builds are fast.

---

## Step 2 — Generate a session secret

The session secret is a 32-byte random value used to sign `webterm-session` cookies with
HMAC-SHA256. It must be stable across restarts so that existing browser sessions remain
valid when webterm restarts.

```bash
openssl rand -hex 32
# example output: a3f8c2...64 hex chars
```

Save this value — it goes into `WEBTERM_SECRET` in the launchd plist.

---

## Step 3 — Generate a password hash (password auth mode)

WebTerm uses PBKDF2-HMAC-SHA256 (200 000 iterations, 16-byte random salt). There is no
built-in `hash-password` subcommand in the binary; generate a hash with a short Swift
one-liner:

```bash
swift -e '
import Foundation
import CommonCrypto
import Security

func pbkdf2(_ password: String) -> String {
    var salt = [UInt8](repeating: 0, count: 16)
    _ = SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt)
    var out = [UInt8](repeating: 0, count: 32)
    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, password.utf8.count,
        salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 200_000, &out, out.count)
    return "pbkdf2$200000$\(Data(salt).base64EncodedString())$\(Data(out).base64EncodedString())"
}
print(pbkdf2("YOUR_CHOSEN_PASSWORD"))
'
```

Replace `YOUR_CHOSEN_PASSWORD` with a strong password (16+ chars recommended). The output
is a string like:

```
pbkdf2$200000$abc123...base64.../$xyz456...base64.../
```

Save this value — it goes into `WEBTERM_PASSWORD_HASH` in the launchd plist.

> **Tip:** To verify a hash manually, you can paste the password and stored hash into
> `PasswordHash.verify(_:against:)` in a Swift test or playground.

---

## Step 4 — Configure cloudflared

### 4a. Authenticate and create a tunnel

```bash
# One-time browser authentication — links cloudflared to your Cloudflare account
cloudflared tunnel login

# Create a named tunnel; this prints a TUNNEL_ID (UUID)
cloudflared tunnel create webterm
```

The credentials JSON is written to `~/.cloudflared/<TUNNEL_ID>.json`.

### 4b. Install the config

Copy the template and fill in the blanks:

```bash
cp /path/to/peer-drop/deploy/cloudflared-config.yml ~/.cloudflared/config.yml
# Edit ~/.cloudflared/config.yml:
#   Replace <TUNNEL_ID> with the UUID from step 4a
#   Replace YOU with your macOS username
#   Replace yourdomain.com with your actual domain
```

### 4c. Route DNS

```bash
# Creates a CNAME record: term.yourdomain.com → <TUNNEL_ID>.cfargotunnel.com
cloudflared tunnel route dns webterm term.yourdomain.com
```

> The domain must already be on Cloudflare (nameservers delegated to Cloudflare).

### 4d. Test the tunnel

```bash
# Run in the foreground to verify; Ctrl-C to stop
cloudflared tunnel run webterm
```

While the tunnel is running, also start webterm (see Step 6) and visit
`https://term.yourdomain.com` in a browser. You should see the login page (after Cloudflare
Access passes you through).

---

## Step 5 — Cloudflare Zero Trust: add an Access Application

1. Open `dash.cloudflare.com` → your account → **Zero Trust** → **Access** →
   **Applications** → **Add an application** → **Self-hosted**.
2. **Application name:** WebTerm (or anything).
3. **Application domain:** `term.yourdomain.com`.
4. **Session duration:** 24h (or your preference).
5. Click **Next** → add a **Policy**:
   - Policy name: Owner
   - Action: Allow
   - Rule: **Emails** → `your@email.com` (the owner's email)
6. Click **Next** → **Add application**.

From now on, visiting `https://term.yourdomain.com` first hits Cloudflare Access, which
presents an email-OTP or SSO flow. Only your email passes through.

---

## Step 6 — Install the launchd user agent

Copy and edit the template:

```bash
# Edit to replace placeholders before installing
cp /path/to/peer-drop/deploy/webterm.launchd.plist \
   ~/Library/LaunchAgents/com.hanfour.webterm.plist

# Required edits in ~/Library/LaunchAgents/com.hanfour.webterm.plist:
#   /Users/YOU  → your actual home directory
#   REPLACE_WITH_HASH → WEBTERM_PASSWORD_HASH from Step 3
#   REPLACE_WITH_64_HEX_CHARS → WEBTERM_SECRET from Step 2
#   term.YOURDOMAIN.com → your actual hostname

# Create the log directory
mkdir -p ~/Library/Logs/webterm

# Load and start immediately
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.hanfour.webterm.plist
```

Verify it started:

```bash
launchctl print gui/$(id -u)/com.hanfour.webterm
# Look for: "state = running"
tail -f ~/Library/Logs/webterm/stdout.log
# Should show: Server started on 127.0.0.1:7681
```

Reload after editing the plist:

```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.hanfour.webterm.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.hanfour.webterm.plist
```

---

## Step 7 — Install the cloudflared launchd agent (always-on tunnel)

```bash
# Installs a system LaunchDaemon that keeps the tunnel running
sudo cloudflared service install
```

Or as a user agent (if you prefer not to use sudo):

```bash
cloudflared service install --user
```

Verify:

```bash
sudo launchctl print system/com.cloudflare.cloudflared
# or (user install):
launchctl print gui/$(id -u)/com.cloudflare.cloudflared
```

---

## Auth modes

### Password mode (recommended — works today)

Set `WEBTERM_PASSWORD_HASH` from Step 3. Leave `CF_ACCESS_AUD`, `CF_ACCESS_TEAM`, and
`CF_ACCESS_OWNER_EMAIL` unset. webterm issues a signed `webterm-session` cookie (24-hour
TTL, HMAC-SHA256).

This is the **recommended mode** for initial deployment. Combined with Cloudflare Access
(Step 5) it gives two independent auth layers.

### Cloudflare-delegated mode (now functional)

Set the three `CF_*` environment variables instead of `WEBTERM_PASSWORD_HASH`:

| Variable | Value |
|---|---|
| `CF_ACCESS_AUD` | The AUD tag from your Cloudflare Access application |
| `CF_ACCESS_TEAM` | Your Cloudflare Zero Trust team name (e.g. `myteam`) |
| `CF_ACCESS_OWNER_EMAIL` | The owner email that must appear in the JWT |

**How to find the AUD tag:** Cloudflare Zero Trust → Access → Applications → open your
app → scroll to the bottom → copy the **Application Audience (AUD) Tag** (a 64-char hex
string).

In this mode webterm fetches the team JWKS from
`https://<team>.cloudflareaccess.com/cdn-cgi/access/certs` at startup, loads the public
keys into a `JWTKeyCollection`, and uses them to validate every `Cf-Access-Jwt-Assertion`
JWT (signature, audience, owner email, and expiry). If the JWKS fetch fails at startup
(bad team name, no network, non-2xx response) webterm prints a clear error and exits
non-zero — it will not start in a broken state.

> **Auto-refresh:** webterm now auto-refreshes the Cloudflare JWKS hourly in a background
> task. Key rotation is handled automatically — no restart needed. On a transient fetch
> failure (network blip, non-2xx response) the previous keys are kept in service
> (fail-stale), so a momentary JWKS endpoint outage will not lock anyone out. Restart is
> only required when changing `CF_ACCESS_TEAM`, `CF_ACCESS_AUD`, or `CF_ACCESS_OWNER_EMAIL`.

Both password mode and Cloudflare-delegated mode are fully functional. Password mode is
the simpler choice for initial deployment; Cloudflare-delegated mode eliminates the need
for a separate password when Cloudflare Access is already the perimeter gate.

---

## Presets

Presets let the frontend offer named "launch into X" buttons (e.g. "Claude Code",
"Monitoring"). They are configured via the `WEBTERM_*` environment variables or by
modifying `main.swift` to pass a `presets:` array to `WebTermConfig`.

The built-in `shell` preset always exists and launches `$SHELL` (or `/bin/zsh`).

To add a preset via `main.swift` (rebuild required):

```swift
let presets = [
    Preset(id: "claude", name: "Claude Code",
           command: "claude",
           cwd: "/path/to/your/project",
           env: nil),
]
let cfg = WebTermConfig(port: port, expectedHost: expectedHost,
                        auth: auth, sessionSecret: sessionSecret,
                        presets: presets)
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `webterm-session` cookie invalid after restart | `WEBTERM_SECRET` not set or changes on restart | Set a stable hex secret (Step 2) |
| Login fails with correct password | Hash was generated for wrong password or was truncated | Regenerate hash (Step 3) |
| 403 / "Origin mismatch" from browser | `WEBTERM_HOST` doesn't match the domain in the browser's `Origin` header | Set `WEBTERM_HOST=term.yourdomain.com` |
| Blank page after login | xterm.js static assets not found in bundle | Ensure binary was built with `swift build` (not `swift run`) from within `PeerDropKit/` |
| Tunnel connects but pages 404 | `httpHostHeader` missing in cloudflared-config.yml | Add `httpHostHeader: "term.yourdomain.com"` to the ingress rule |
| `tmux: no server running` | tmux not in PATH for the launchd process | Add `/opt/homebrew/bin` to `PATH` in the plist `EnvironmentVariables` |

---

## Known follow-ups

**(a) ✅ Fixed — Cloudflare-delegated mode is now functional, with hourly JWKS auto-refresh.**
`CfAccessKeys.fetch(team:)` fetches the JWKS at startup; `main.swift` builds a
`CfAccessVerifier` (backed by a `CfAccessKeySource` actor) and immediately starts a
background `Task` that re-fetches and swaps in the latest keys every 3600 seconds.
On a transient fetch failure the previous keys are kept (fail-stale). No restart needed
on Cloudflare key rotation.

**(b) Mobile on-screen key bar (Phase 2).** The xterm.js frontend has no special key
overlay for mobile browsers (Escape, Ctrl, arrow keys are inaccessible on on-screen
keyboards). A Phase 2 bar of common keys would make mobile use practical.

**(c) OAuth / third-party login (Phase 2).** Currently only password and Cloudflare
Access are supported. Adding Google / GitHub OAuth would allow the Cloudflare-free path
without a shared password.

**(d) ✅ Fixed — WS endpoint now create-or-attaches via `SessionManager`.**
`WebServer.swift`'s `/ws/:sessionId` handler calls `SessionManager.openSession(presetID:)`
which runs `TmuxControl.createIfNeeded` before connecting, so a fresh server no longer
rejects the first WebSocket connection. Multiple concurrent browser tabs share one cached
`TerminalSession` object; `TerminalSession.start()` is idempotent (second call is a no-op).

**(e) Reboot auto-recreate of tmux sessions (Phase 2).** After a machine reboot, tmux
sessions are gone. The frontend will reconnect to webterm but find no live sessions.
A Phase 2 enhancement could auto-recreate a default session on startup (e.g. via
`SessionManager` initialisation) or add a "relaunch" button in the UI.
