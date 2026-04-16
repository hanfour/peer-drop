# Relay Auto-Invite System + Connection Fix Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a WebSocket + APNs invite system so Creator selects a known device, Joiner receives an auto-invite, and both auto-connect. Fix the existing -1011 relay WebSocket failure by carrying the room token in the invite payload.

**Architecture:**
- Worker: New `DeviceInbox` Durable Object for real-time WS inbox; new `/v2/device/register`, `/v2/inbox/:deviceId`, `/v2/invite/:deviceId` endpoints; APNs HTTP/2 push integration.
- iOS: `InboxService` (foreground WS) + `PushNotificationManager` (APNs) + `InviteBanner` UI + `DevicePickerView` (invite sender) + deviceId exchange on first relay connection.
- Fix: Include roomToken in invite payload (skips race-prone ICE→token fetch). Worker logs WS auth failures; iOS retries WS on -1011.

**Tech Stack:** Swift 5.9 / SwiftUI / URLSessionWebSocketTask / UserNotifications framework / TypeScript (Cloudflare Workers) / Durable Objects / APNs HTTP/2 + JWT.

**Reference Document:** `docs/plans/2026-04-16-relay-invite-and-fix-design.md`

---

## Phase 1 — Worker: Diagnostic Logging + Relay Fixes

Ship diagnostic logging + relay reliability fixes **first**, so next real-device test yields concrete error codes.

### Task 1.1: Add WebSocket auth-failure diagnostic logging

**Files:**
- Modify: `cloudflare-worker/src/index.ts:152-178` (WebSocket upgrade handler)

**Step 1: Edit the WebSocket route handler to log failures**

Replace the block at lines 152-178 with:

```typescript
// WebSocket /room/:code?token=xxx — signaling relay (delegated to Durable Object)
const wsMatch = path.match(/^\/room\/([A-Z0-9]{6})$/);
if (wsMatch && request.headers.get("Upgrade") === "websocket") {
  const code = wsMatch[1];
  const roomData = await env.ROOMS.get(code);
  if (!roomData) {
    // Diagnostic: log WS upgrade failures (7-day TTL)
    const logKey = `wslog:${Date.now()}:${Math.random().toString(36).slice(2, 8)}`;
    await env.ROOMS.put(logKey, JSON.stringify({
      reason: "room_not_found",
      code,
      ip: clientIP,
      ua: request.headers.get("User-Agent") || "",
      timestamp: new Date().toISOString(),
    }), { expirationTtl: 7 * 86400 });
    return new Response(JSON.stringify({ error: "Room not found" }), {
      status: 404,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const roomInfo = JSON.parse(roomData) as { token?: string };
  const providedToken = url.searchParams.get("token");
  if (!providedToken || providedToken !== roomInfo.token) {
    const logKey = `wslog:${Date.now()}:${Math.random().toString(36).slice(2, 8)}`;
    await env.ROOMS.put(logKey, JSON.stringify({
      reason: "invalid_token",
      code,
      providedToken: providedToken ? `${providedToken.slice(0, 4)}...${providedToken.slice(-4)}` : null,
      expectedTokenHash: roomInfo.token ? `${roomInfo.token.slice(0, 4)}...${roomInfo.token.slice(-4)}` : null,
      ip: clientIP,
      ua: request.headers.get("User-Agent") || "",
      timestamp: new Date().toISOString(),
    }), { expirationTtl: 7 * 86400 });
    return new Response(JSON.stringify({ error: "Invalid room token" }), {
      status: 403,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const id = env.SIGNALING_ROOM.idFromName(code);
  const stub = env.SIGNALING_ROOM.get(id);
  return stub.fetch(request);
}
```

**Step 2: Deploy and verify**

Run: `cd cloudflare-worker && npx wrangler deploy`
Expected: `✨ Successfully deployed`

**Step 3: Smoke test — provoke a 404**

Run: `curl -i "https://peerdrop-signal.hanfourhuang.workers.dev/room/ZZZZZZ" -H "Upgrade: websocket" -H "Connection: upgrade" -H "Sec-WebSocket-Key: abcdefghijklmnop==" -H "Sec-WebSocket-Version: 13"`
Expected: `HTTP/2 404` with `{"error":"Room not found"}`

**Step 4: Verify log was written**

Run:
```bash
TOKEN=$(grep oauth_token /Users/hanfourmini/Library/Preferences/.wrangler/config/default.toml | sed 's/.*= "//;s/"//')
curl -s "https://api.cloudflare.com/client/v4/accounts/22d9d417c1d3ab5d72aa9aedc0cc183c/storage/kv/namespaces/376d9f22d4c743bfb1509b814087192c/keys?prefix=wslog:&limit=5" -H "Authorization: Bearer $TOKEN" | python3 -m json.tool
```
Expected: at least one `wslog:...` key

**Step 5: Commit**

```bash
git add cloudflare-worker/src/index.ts
git commit -m "feat(worker): log WebSocket auth failures to KV for diagnostics"
```

---

### Task 1.2: Increase ROOM_TTL_SECONDS from 300 to 600

**Files:**
- Modify: `cloudflare-worker/src/index.ts:26`

**Step 1: Edit the constant**

Change line 26 from `const ROOM_TTL_SECONDS = 300;` to `const ROOM_TTL_SECONDS = 600;`.

**Step 2: Deploy**

Run: `cd cloudflare-worker && npx wrangler deploy`
Expected: successful deploy

**Step 3: Commit**

```bash
git add cloudflare-worker/src/index.ts
git commit -m "fix(worker): increase room TTL 5→10 min to reduce expiry during invite flow"
```

---

## Phase 2 — Worker: Device Inbox Infrastructure

### Task 2.1: Add DeviceInbox Durable Object skeleton (no APNs yet)

**Files:**
- Modify: `cloudflare-worker/src/index.ts` (add new DO class at end of file, before closing)
- Modify: `cloudflare-worker/wrangler.toml` (add new DO binding + migration)

**Step 1: Add DeviceInbox class**

Append to `cloudflare-worker/src/index.ts` after `PreKeyStore` class:

```typescript
// ---------------------------------------------------------------------------
// Durable Object: DeviceInbox
// Each device maps to one DO. Holds the foreground WebSocket for real-time
// invite delivery. Falls back to APNs + KV queue when WS is absent.
// ---------------------------------------------------------------------------

export class DeviceInbox {
  private state: DurableObjectState;
  private env: Env;

  constructor(state: DurableObjectState, env: Env) {
    this.state = state;
    this.env = env;
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    // GET /ws — upgrade to WebSocket
    if (url.pathname === "/ws" && request.headers.get("Upgrade") === "websocket") {
      const pair = new WebSocketPair();
      const [client, server] = Object.values(pair);
      this.state.acceptWebSocket(server);

      // Flush any queued invites
      const queue = await this.state.storage.list<string>({ prefix: "queue:" });
      for (const [key, value] of queue) {
        try {
          server.send(value);
        } catch { /* socket already bad, abort */ break; }
        await this.state.storage.delete(key);
      }

      return new Response(null, { status: 101, webSocket: client });
    }

    // POST /push — deliver invite (from /v2/invite/:deviceId handler)
    if (url.pathname === "/push" && request.method === "POST") {
      const payload = await request.text();
      const sockets = this.state.getWebSockets();
      if (sockets.length > 0) {
        let delivered = false;
        for (const ws of sockets) {
          try { ws.send(payload); delivered = true; } catch { /* skip */ }
        }
        if (delivered) return jsonResponse({ delivered: "websocket" });
      }

      // No live socket → queue + caller will send APNs
      const queueKey = `queue:${Date.now()}:${Math.random().toString(36).slice(2, 8)}`;
      await this.state.storage.put(queueKey, payload);
      // Auto-clean old queue entries (keep last 20)
      const all = await this.state.storage.list<string>({ prefix: "queue:" });
      const keys = Array.from(all.keys()).sort();
      while (keys.length > 20) {
        const oldest = keys.shift();
        if (oldest) await this.state.storage.delete(oldest);
      }
      return jsonResponse({ delivered: "queued" });
    }

    return new Response("Not Found", { status: 404 });
  }

  // Hibernation API
  webSocketClose(ws: WebSocket) {
    try { ws.close(); } catch { /* already closed */ }
  }
  webSocketError(ws: WebSocket) {
    try { ws.close(1011, "error"); } catch { /* already closed */ }
  }
}
```

**Step 2: Update Env interface**

Edit `cloudflare-worker/src/index.ts` lines 13-21 to add `DEVICE_INBOX: DurableObjectNamespace;`:

```typescript
export interface Env {
  ROOMS: KVNamespace;
  V2_STORE: KVNamespace;
  SIGNALING_ROOM: DurableObjectNamespace;
  PREKEY_STORE: DurableObjectNamespace;
  DEVICE_INBOX: DurableObjectNamespace;
  TURN_KEY_ID: string;
  TURN_API_TOKEN: string;
  API_KEY: string;
}
```

**Step 3: Update wrangler.toml**

Edit `cloudflare-worker/wrangler.toml` — add a DO binding and migration:

```toml
[[durable_objects.bindings]]
name = "DEVICE_INBOX"
class_name = "DeviceInbox"

[[migrations]]
tag = "v3"
new_sqlite_classes = ["DeviceInbox"]
```

Append these to the existing migrations list.

**Step 4: Deploy**

Run: `cd cloudflare-worker && npx wrangler deploy`
Expected: `Successfully deployed` with new DO migration `v3` applied.

**Step 5: Commit**

```bash
git add cloudflare-worker/src/index.ts cloudflare-worker/wrangler.toml
git commit -m "feat(worker): add DeviceInbox Durable Object for real-time invite delivery"
```

---

### Task 2.2: Add /v2/device/register endpoint

**Files:**
- Modify: `cloudflare-worker/src/index.ts` (insert new route before line 508 catch-all)

**Step 1: Add the route**

Insert just before `return new Response("Not Found", { status: 404, headers: corsHeaders });` at line 508:

```typescript
// POST /v2/device/register — register APNs device token
if (path === "/v2/device/register" && request.method === "POST") {
  const body = await request.json() as { deviceId?: string; pushToken?: string; platform?: string };
  if (!body.deviceId || !body.pushToken) {
    return jsonResponse({ error: "Missing deviceId or pushToken" }, 400);
  }
  if (!/^[a-zA-Z0-9-]{8,64}$/.test(body.deviceId)) {
    return jsonResponse({ error: "Invalid deviceId format" }, 400);
  }
  await env.V2_STORE.put(`device:${body.deviceId}`, JSON.stringify({
    pushToken: body.pushToken,
    platform: body.platform || "ios",
    updated: Date.now(),
  }), { expirationTtl: 30 * 86400 });
  return jsonResponse({ ok: true });
}
```

**Step 2: Deploy and test**

Run:
```bash
cd cloudflare-worker && npx wrangler deploy
curl -s -X POST https://peerdrop-signal.hanfourhuang.workers.dev/v2/device/register \
  -H "Content-Type: application/json" \
  -d '{"deviceId":"test-device-123","pushToken":"deadbeef","platform":"ios"}'
```
Expected: `{"ok":true}`

**Step 3: Verify stored**

```bash
TOKEN=$(grep oauth_token /Users/hanfourmini/Library/Preferences/.wrangler/config/default.toml | sed 's/.*= "//;s/"//')
curl -s "https://api.cloudflare.com/client/v4/accounts/22d9d417c1d3ab5d72aa9aedc0cc183c/storage/kv/namespaces/9968f53e396f441da9e9fa419285ed68/values/device:test-device-123" -H "Authorization: Bearer $TOKEN"
```
Expected: JSON with pushToken + platform + updated

**Step 4: Commit**

```bash
git add cloudflare-worker/src/index.ts
git commit -m "feat(worker): add /v2/device/register endpoint for APNs token storage"
```

---

### Task 2.3: Add /v2/inbox/:deviceId WebSocket endpoint

**Files:**
- Modify: `cloudflare-worker/src/index.ts` (insert new route before catch-all)

**Step 1: Add the route**

Insert before `return new Response("Not Found", { status: 404, headers: corsHeaders });`:

```typescript
// GET /v2/inbox/:deviceId — WebSocket upgrade for real-time invite inbox
const inboxMatch = path.match(/^\/v2\/inbox\/([a-zA-Z0-9-]{8,64})$/);
if (inboxMatch && request.headers.get("Upgrade") === "websocket") {
  const deviceId = inboxMatch[1];
  const id = env.DEVICE_INBOX.idFromName(deviceId);
  const stub = env.DEVICE_INBOX.get(id);
  const doURL = new URL(request.url);
  doURL.pathname = "/ws";
  return stub.fetch(new Request(doURL.toString(), request));
}
```

**Step 2: Deploy**

Run: `cd cloudflare-worker && npx wrangler deploy`

**Step 3: Smoke test the WebSocket**

Run:
```bash
npx wscat -c "wss://peerdrop-signal.hanfourhuang.workers.dev/v2/inbox/test-device-123" &
WS_PID=$!
sleep 2; kill $WS_PID 2>/dev/null
```
Expected: connection succeeds (no immediate rejection).

If wscat isn't installed: `npm install -g wscat` first.

**Step 4: Commit**

```bash
git add cloudflare-worker/src/index.ts
git commit -m "feat(worker): add /v2/inbox/:deviceId WebSocket endpoint"
```

---

### Task 2.4: Add /v2/invite/:deviceId endpoint (no APNs yet — stub)

**Files:**
- Modify: `cloudflare-worker/src/index.ts` (insert before catch-all)

**Step 1: Add the route**

Insert before catch-all:

```typescript
// POST /v2/invite/:deviceId — deliver relay invite
const inviteMatch = path.match(/^\/v2\/invite\/([a-zA-Z0-9-]{8,64})$/);
if (inviteMatch && request.method === "POST") {
  const deviceId = inviteMatch[1];
  const body = await request.json() as {
    roomCode?: string;
    roomToken?: string;
    senderName?: string;
    senderId?: string;
  };
  if (!body.roomCode || !body.roomToken || !body.senderName) {
    return jsonResponse({ error: "Missing invite fields" }, 400);
  }

  const invitePayload = JSON.stringify({
    type: "relay-invite",
    roomCode: body.roomCode,
    roomToken: body.roomToken,
    senderName: body.senderName,
    senderId: body.senderId || "",
    timestamp: Date.now(),
  });

  // Push via DeviceInbox DO
  const id = env.DEVICE_INBOX.idFromName(deviceId);
  const stub = env.DEVICE_INBOX.get(id);
  const pushURL = new URL(request.url);
  pushURL.pathname = "/push";
  const doResp = await stub.fetch(new Request(pushURL.toString(), {
    method: "POST",
    body: invitePayload,
  }));
  const doResult = await doResp.json() as { delivered: string };

  // If queued, try APNs (stub for now — Phase 3)
  if (doResult.delivered === "queued") {
    // TODO Phase 3: send APNs push
    return jsonResponse({ ok: true, delivered: "queued" });
  }

  return jsonResponse({ ok: true, delivered: doResult.delivered });
}
```

**Step 2: Deploy**

Run: `cd cloudflare-worker && npx wrangler deploy`

**Step 3: End-to-end WS + invite test**

Terminal 1 (keep open):
```bash
npx wscat -c "wss://peerdrop-signal.hanfourhuang.workers.dev/v2/inbox/test-device-123"
```

Terminal 2:
```bash
curl -s -X POST https://peerdrop-signal.hanfourhuang.workers.dev/v2/invite/test-device-123 \
  -H "Content-Type: application/json" \
  -d '{"roomCode":"ABCDEF","roomToken":"test-token","senderName":"Test Sender","senderId":"creator-dev-id"}'
```
Expected: Terminal 1 receives `{"type":"relay-invite","roomCode":"ABCDEF",...}`. Terminal 2 prints `{"ok":true,"delivered":"websocket"}`.

**Step 4: Test queued path**

With no WS open:
```bash
curl -s -X POST https://peerdrop-signal.hanfourhuang.workers.dev/v2/invite/test-device-offline \
  -H "Content-Type: application/json" \
  -d '{"roomCode":"ABCDEF","roomToken":"t","senderName":"S"}'
```
Expected: `{"ok":true,"delivered":"queued"}`

Then open WS to `test-device-offline` — queued invite should be flushed instantly.

**Step 5: Commit**

```bash
git add cloudflare-worker/src/index.ts
git commit -m "feat(worker): add /v2/invite/:deviceId endpoint with WS + queue delivery"
```

---

## Phase 3 — Worker: APNs Push Integration

### Task 3.1: APNs JWT signing helper

**Files:**
- Create: `cloudflare-worker/src/apns.ts`

**Step 1: Write the APNs module**

```typescript
// APNs HTTP/2 push client for Cloudflare Workers.
// Uses JWT provider token authentication.

interface APNsConfig {
  keyId: string;
  teamId: string;
  p8Key: string; // PEM-formatted ECDSA P-256 key
  bundleId: string;
}

export interface APNsPayload {
  alert?: { title: string; body: string };
  sound?: string;
  contentAvailable?: boolean;
  customData?: Record<string, unknown>;
}

// Cache JWT for up to 50 minutes (APNs limit is 1 hour)
let cachedJWT: { token: string; expires: number } | null = null;

async function signJWT(config: APNsConfig): Promise<string> {
  if (cachedJWT && Date.now() < cachedJWT.expires) return cachedJWT.token;

  const header = { alg: "ES256", kid: config.keyId };
  const payload = { iss: config.teamId, iat: Math.floor(Date.now() / 1000) };

  const b64url = (obj: unknown) => {
    const s = btoa(JSON.stringify(obj));
    return s.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  };
  const signingInput = `${b64url(header)}.${b64url(payload)}`;

  // Parse P-256 PEM
  const pemBody = config.p8Key
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replace(/\s/g, "");
  const pkcs8 = Uint8Array.from(atob(pemBody), c => c.charCodeAt(0));

  const key = await crypto.subtle.importKey(
    "pkcs8",
    pkcs8,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"]
  );
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(signingInput)
  );
  const sigB64 = btoa(String.fromCharCode(...new Uint8Array(signature)))
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

  const token = `${signingInput}.${sigB64}`;
  cachedJWT = { token, expires: Date.now() + 50 * 60 * 1000 };
  return token;
}

export async function sendAPNs(
  deviceToken: string,
  payload: APNsPayload,
  config: APNsConfig
): Promise<{ ok: boolean; status: number; error?: string }> {
  const jwt = await signJWT(config);

  const apsBody: Record<string, unknown> = { aps: {} };
  const aps = apsBody.aps as Record<string, unknown>;
  if (payload.alert) aps.alert = payload.alert;
  if (payload.sound) aps.sound = payload.sound;
  if (payload.contentAvailable) aps["content-available"] = 1;
  if (payload.customData) Object.assign(apsBody, payload.customData);

  const resp = await fetch(`https://api.push.apple.com/3/device/${deviceToken}`, {
    method: "POST",
    headers: {
      "authorization": `bearer ${jwt}`,
      "apns-topic": config.bundleId,
      "apns-push-type": "alert",
      "content-type": "application/json",
    },
    body: JSON.stringify(apsBody),
  });

  if (resp.ok) return { ok: true, status: resp.status };
  const errText = await resp.text();
  return { ok: false, status: resp.status, error: errText };
}
```

**Step 2: Commit**

```bash
git add cloudflare-worker/src/apns.ts
git commit -m "feat(worker): add APNs HTTP/2 JWT-signed push client"
```

---

### Task 3.2: Wire APNs into /v2/invite/:deviceId

**Files:**
- Modify: `cloudflare-worker/src/index.ts` — update Env interface and invite handler
- Modify: `cloudflare-worker/wrangler.toml` (document new secrets)

**Step 1: Extend Env interface**

Add to Env (around line 13-21):
```typescript
APNS_KEY_P8: string;
APNS_KEY_ID: string;
APNS_TEAM_ID: string;
APNS_BUNDLE_ID: string;
```

**Step 2: Import APNs helper**

At top of `index.ts`, add:
```typescript
import { sendAPNs } from "./apns";
```

**Step 3: Replace the stub APNs TODO in /v2/invite/:deviceId**

Find the `if (doResult.delivered === "queued") { ... TODO ...}` block and replace with:

```typescript
if (doResult.delivered === "queued") {
  // Look up APNs token for this device
  const deviceInfo = await env.V2_STORE.get(`device:${deviceId}`);
  if (!deviceInfo) {
    return jsonResponse({ ok: true, delivered: "queued", apns: "no_token" });
  }
  const info = JSON.parse(deviceInfo) as { pushToken: string; platform: string };
  if (info.platform !== "ios" || !env.APNS_KEY_P8) {
    return jsonResponse({ ok: true, delivered: "queued", apns: "not_configured" });
  }
  try {
    const result = await sendAPNs(info.pushToken, {
      alert: { title: "PeerDrop", body: `${body.senderName} wants to connect` },
      sound: "default",
      customData: {
        roomCode: body.roomCode,
        roomToken: body.roomToken,
        senderId: body.senderId || "",
      },
    }, {
      keyId: env.APNS_KEY_ID,
      teamId: env.APNS_TEAM_ID,
      p8Key: env.APNS_KEY_P8,
      bundleId: env.APNS_BUNDLE_ID || "com.hanfour.peerdrop",
    });
    return jsonResponse({ ok: true, delivered: "apns", apnsStatus: result.status });
  } catch (e) {
    return jsonResponse({ ok: true, delivered: "queued", apns: "send_failed", error: String(e) });
  }
}
```

**Step 4: Set secrets (MANUAL — user action required)**

Instruct the user to run:
```bash
cd cloudflare-worker
cat /path/to/AuthKey_XXXXXXXX.p8 | npx wrangler secret put APNS_KEY_P8
npx wrangler secret put APNS_KEY_ID     # enter the key ID (e.g. A1B2C3D4E5)
npx wrangler secret put APNS_TEAM_ID    # enter the Apple developer team ID
npx wrangler secret put APNS_BUNDLE_ID  # enter com.hanfour.peerdrop
```

**PAUSE here** — do not continue until user confirms secrets are set.

**Step 5: Deploy and verify**

Run: `cd cloudflare-worker && npx wrangler deploy`
Then test with a real device (after Phase 4 iOS work), not here.

**Step 6: Commit**

```bash
git add cloudflare-worker/src/index.ts cloudflare-worker/wrangler.toml
git commit -m "feat(worker): send APNs push when invite is queued (WS offline)"
```

---

## Phase 4 — iOS: Device ID + Push Registration Plumbing

### Task 4.1: Generate and persist stable deviceId

**Files:**
- Create: `PeerDrop/Core/DeviceIdentity.swift`
- Test: `PeerDropTests/DeviceIdentityTests.swift`

**Step 1: Write the test**

```swift
import XCTest
@testable import PeerDrop

final class DeviceIdentityTests: XCTestCase {
    func test_deviceId_isStableAcrossCalls() {
        UserDefaults.standard.removeObject(forKey: "peerDropDeviceId")
        let first = DeviceIdentity.deviceId
        let second = DeviceIdentity.deviceId
        XCTAssertEqual(first, second)
        XCTAssertFalse(first.isEmpty)
        XCTAssertGreaterThanOrEqual(first.count, 16)
    }

    func test_deviceId_matchesExpectedFormat() {
        UserDefaults.standard.removeObject(forKey: "peerDropDeviceId")
        let id = DeviceIdentity.deviceId
        // UUID string like D1234567-89AB-CDEF-...
        XCTAssertTrue(id.range(of: "^[A-F0-9-]{36}$", options: .regularExpression) != nil)
    }
}
```

**Step 2: Run the test — expect FAIL**

```bash
xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/DeviceIdentityTests
```
Expected: `Cannot find 'DeviceIdentity' in scope`

**Step 3: Implement DeviceIdentity**

```swift
import Foundation

/// Stable per-install device identifier used for routing invites and APNs pushes.
enum DeviceIdentity {
    private static let key = "peerDropDeviceId"

    static var deviceId: String {
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: key)
        return newId
    }
}
```

**Step 4: Regenerate Xcode project**

Run: `cd "/Volumes/SATECHI DISK Media/UserFolders/Projects/applications/peer-drop" && xcodegen generate`

**Step 5: Run the test — expect PASS**

```bash
xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/DeviceIdentityTests
```
Expected: 2 tests passing.

**Step 6: Commit**

```bash
git add PeerDrop/Core/DeviceIdentity.swift PeerDropTests/DeviceIdentityTests.swift project.yml PeerDrop.xcodeproj
git commit -m "feat(ios): add DeviceIdentity for stable per-install UUID"
```

---

### Task 4.2: Add remote-notification background mode

**Files:**
- Modify: `project.yml:73-76` (UIBackgroundModes list)
- Modify: `PeerDrop/App/Info.plist:54-59` (UIBackgroundModes list)

**Step 1: Add remote-notification to project.yml**

Find the UIBackgroundModes block (around lines 73-76) and append `remote-notification` to the list.

**Step 2: Add to Info.plist**

Add `<string>remote-notification</string>` inside the `UIBackgroundModes` array in Info.plist.

**Step 3: Regenerate + verify build**

```bash
cd "/Volumes/SATECHI DISK Media/UserFolders/Projects/applications/peer-drop"
xcodegen generate
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet
```
Expected: `BUILD SUCCEEDED`

**Step 4: Commit**

```bash
git add project.yml PeerDrop/App/Info.plist PeerDrop.xcodeproj
git commit -m "feat(ios): enable remote-notification background mode"
```

---

### Task 4.3: PushNotificationManager — register device token

**Files:**
- Create: `PeerDrop/Core/PushNotificationManager.swift`
- Modify: `PeerDrop/App/AppDelegate.swift` (add didRegisterForRemoteNotifications and didReceiveRemoteNotification)
- Modify: `PeerDrop/App/PeerDropApp.swift:13` (trigger registration at launch)

**Step 1: Write PushNotificationManager**

```swift
import Foundation
import UIKit
import UserNotifications
import os.log

/// Handles APNs registration and invite push payload parsing.
@MainActor
final class PushNotificationManager: NSObject, ObservableObject {
    static let shared = PushNotificationManager()
    private let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "PushNotificationManager")

    /// Emits when a push-delivered invite arrives (App in background or tap on notification).
    @Published var receivedInvite: RelayInvite?

    private override init() { super.init() }

    func requestAuthorizationAndRegister() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            guard granted else { logger.info("Push permission denied"); return }
            await UIApplication.shared.registerForRemoteNotifications()
        } catch {
            logger.error("Push authorization failed: \(error.localizedDescription)")
        }
    }

    func handleDeviceToken(_ deviceToken: Data) async {
        let tokenHex = deviceToken.map { String(format: "%02x", $0) }.joined()
        logger.info("APNs token: \(tokenHex.prefix(8))...")

        let baseURL = UserDefaults.standard.string(forKey: "peerDropWorkerURL")
            ?? "https://peerdrop-signal.hanfourhuang.workers.dev"
        guard let url = URL(string: "\(baseURL)/v2/device/register") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "deviceId": DeviceIdentity.deviceId,
            "pushToken": tokenHex,
            "platform": "ios",
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                logger.info("Device registered with worker")
            }
        } catch {
            logger.error("Device register failed: \(error.localizedDescription)")
        }
    }

    /// Parse an APNs payload into a RelayInvite.
    func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) {
        guard let roomCode = userInfo["roomCode"] as? String,
              let roomToken = userInfo["roomToken"] as? String else {
            logger.warning("Ignoring push without invite fields")
            return
        }
        let senderName = (userInfo["aps"] as? [String: Any])
            .flatMap { ($0["alert"] as? [String: String])?["body"] }
            ?? "Unknown"
        let senderId = userInfo["senderId"] as? String ?? ""
        receivedInvite = RelayInvite(
            roomCode: roomCode,
            roomToken: roomToken,
            senderName: senderName,
            senderId: senderId,
            source: .apns
        )
    }
}

/// Shared invite payload model.
struct RelayInvite: Identifiable, Equatable {
    enum Source { case websocket, apns }
    var id: String { roomCode + ":" + (senderId.isEmpty ? senderName : senderId) }
    let roomCode: String
    let roomToken: String
    let senderName: String
    let senderId: String
    let source: Source
}
```

**Step 2: Modify AppDelegate**

Open `PeerDrop/App/AppDelegate.swift`, append to the class:

```swift
func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    Task { await PushNotificationManager.shared.handleDeviceToken(deviceToken) }
}

func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
    // Silently ignore — push is a nice-to-have
}

func application(_ application: UIApplication,
                 didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                 fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
    Task { @MainActor in
        PushNotificationManager.shared.handleRemoteNotification(userInfo)
        completionHandler(.newData)
    }
}
```

**Step 3: Trigger registration at app launch**

In `PeerDrop/App/PeerDropApp.swift`, find the init or App.onAppear. After existing launch code, add:

```swift
.task {
    await PushNotificationManager.shared.requestAuthorizationAndRegister()
}
```

Place this on the root WindowGroup content view (e.g., ContentView()).

**Step 4: Build**

```bash
xcodegen generate
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet
```
Expected: BUILD SUCCEEDED.

**Step 5: Commit**

```bash
git add PeerDrop/Core/PushNotificationManager.swift PeerDrop/App/AppDelegate.swift PeerDrop/App/PeerDropApp.swift project.yml PeerDrop.xcodeproj
git commit -m "feat(ios): add PushNotificationManager for APNs registration"
```

---

## Phase 5 — iOS: InboxService (Foreground WebSocket)

### Task 5.1: Write InboxService tests first

**Files:**
- Create: `PeerDropTests/InboxServiceTests.swift`

**Step 1: Write tests against a mock URLSession**

```swift
import XCTest
import Combine
@testable import PeerDrop

final class InboxServiceTests: XCTestCase {

    func test_parsesInviteMessage() {
        let service = InboxService(deviceId: "test-id")
        let json = """
        {"type":"relay-invite","roomCode":"ABC123","roomToken":"tok","senderName":"Alice","senderId":"a-id","timestamp":1234}
        """
        let invite = service.parseMessage(json)
        XCTAssertEqual(invite?.roomCode, "ABC123")
        XCTAssertEqual(invite?.roomToken, "tok")
        XCTAssertEqual(invite?.senderName, "Alice")
        XCTAssertEqual(invite?.source, .websocket)
    }

    func test_ignoresNonInviteMessages() {
        let service = InboxService(deviceId: "test-id")
        let invite = service.parseMessage(#"{"type":"ping"}"#)
        XCTAssertNil(invite)
    }

    func test_ignoresMalformedJson() {
        let service = InboxService(deviceId: "test-id")
        XCTAssertNil(service.parseMessage("not json"))
    }
}
```

**Step 2: Run — expect FAIL** (InboxService not found)

```bash
xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/InboxServiceTests
```

**Step 3: Commit just the failing test**

```bash
git add PeerDropTests/InboxServiceTests.swift
git commit -m "test(ios): add InboxService parse tests (TDD red)"
```

---

### Task 5.2: Implement InboxService

**Files:**
- Create: `PeerDrop/Core/InboxService.swift`

**Step 1: Implement**

```swift
import Foundation
import os.log

@MainActor
final class InboxService: NSObject, ObservableObject {
    private let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "InboxService")
    private let deviceId: String
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?

    @Published var isConnected: Bool = false
    @Published var receivedInvite: RelayInvite?

    init(deviceId: String = DeviceIdentity.deviceId) {
        self.deviceId = deviceId
        super.init()
    }

    func connect() {
        disconnect()
        let base = UserDefaults.standard.string(forKey: "peerDropWorkerURL")
            ?? "https://peerdrop-signal.hanfourhuang.workers.dev"
        guard var components = URLComponents(string: base) else { return }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/v2/inbox/\(deviceId)"
        guard let url = components.url else { return }

        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config)
        let task = session.webSocketTask(with: url)
        webSocketTask = task
        task.resume()
        isConnected = true
        logger.info("Inbox WS connecting for device: \(self.deviceId.prefix(8))")
        startReceive()
        startPing()
    }

    func disconnect() {
        pingTask?.cancel(); pingTask = nil
        receiveTask?.cancel(); receiveTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
    }

    /// Parses a JSON string into a RelayInvite if valid. (Exposed for unit tests.)
    nonisolated func parseMessage(_ text: String) -> RelayInvite? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["type"] as? String) == "relay-invite",
              let code = obj["roomCode"] as? String,
              let token = obj["roomToken"] as? String,
              let sender = obj["senderName"] as? String else {
            return nil
        }
        return RelayInvite(
            roomCode: code,
            roomToken: token,
            senderName: sender,
            senderId: obj["senderId"] as? String ?? "",
            source: .websocket
        )
    }

    private func startReceive() {
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let task = await self.webSocketTask else { break }
                do {
                    let message = try await task.receive()
                    let text: String?
                    switch message {
                    case .string(let s): text = s
                    case .data(let d): text = String(data: d, encoding: .utf8)
                    @unknown default: text = nil
                    }
                    if let text, let invite = self.parseMessage(text) {
                        await MainActor.run { self.receivedInvite = invite }
                    }
                } catch {
                    await MainActor.run {
                        self.logger.info("Inbox WS closed: \(error.localizedDescription)")
                        self.isConnected = false
                    }
                    break
                }
            }
        }
    }

    private func startPing() {
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self, let task = await self.webSocketTask else { break }
                task.sendPing { error in
                    // Silently tolerate ping errors (will be detected by receive loop)
                    _ = error
                }
            }
        }
    }
}
```

**Step 2: Regenerate + run tests — expect PASS**

```bash
xcodegen generate
xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/InboxServiceTests
```
Expected: 3 tests passing.

**Step 3: Commit**

```bash
git add PeerDrop/Core/InboxService.swift project.yml PeerDrop.xcodeproj
git commit -m "feat(ios): implement InboxService with parse + WS lifecycle"
```

---

### Task 5.3: Wire InboxService to app lifecycle (foreground connect / background disconnect)

**Files:**
- Modify: `PeerDrop/App/PeerDropApp.swift:88-101` (scenePhase handler)

**Step 1: Add InboxService as StateObject**

In PeerDropApp.swift, add near the other @StateObject declarations:
```swift
@StateObject private var inboxService = InboxService()
```

And pass into environment or ContentView as needed:
```swift
ContentView()
    .environmentObject(inboxService)
```

**Step 2: Connect on foreground, disconnect on background**

Update the `.onChange(of: scenePhase)` block (lines 88-101) to add:

```swift
.onChange(of: scenePhase) { _, newPhase in
    switch newPhase {
    case .active:
        inboxService.connect()
    case .background, .inactive:
        inboxService.disconnect()
    @unknown default:
        break
    }
    // ... existing save-state code ...
}
```

**Step 3: Build**

```bash
xcodegen generate
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet
```
Expected: BUILD SUCCEEDED.

**Step 4: Commit**

```bash
git add PeerDrop/App/PeerDropApp.swift
git commit -m "feat(ios): connect/disconnect InboxService on scene phase changes"
```

---

## Phase 6 — iOS: Invite Banner UI + Auto-Join

### Task 6.1: InviteBanner view

**Files:**
- Create: `PeerDrop/UI/Relay/InviteBanner.swift`

**Step 1: Write the view**

```swift
import SwiftUI

struct InviteBanner: View {
    let invite: RelayInvite
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.wave.2.fill")
                .font(.title2)
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text(invite.senderName)
                    .font(.subheadline).bold()
                    .foregroundStyle(.white)
                Text("wants to connect")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
            }
            Spacer()
            Button(action: onDecline) {
                Text("Decline")
                    .font(.caption).bold()
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.white.opacity(0.2), in: Capsule())
                    .foregroundStyle(.white)
            }
            Button(action: onAccept) {
                Text("Accept")
                    .font(.caption).bold()
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.white, in: Capsule())
                    .foregroundStyle(.blue)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            LinearGradient(colors: [.blue, .indigo], startPoint: .leading, endPoint: .trailing),
            in: RoundedRectangle(cornerRadius: 14)
        )
        .padding(.horizontal, 10)
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
    }
}
```

**Step 2: Localize key strings (add to Localizable.xcstrings)**

Add keys: `"wants to connect"`, `"Accept"`, `"Decline"` — zh-Hant equivalents: `"想與你建立連線"`, `"接受"`, `"拒絕"`. Update the String Catalog via Xcode OR manually edit `PeerDrop/App/Localizable.xcstrings`.

**Step 3: Commit**

```bash
git add PeerDrop/UI/Relay/InviteBanner.swift PeerDrop/App/Localizable.xcstrings project.yml PeerDrop.xcodeproj
git commit -m "feat(ios): add InviteBanner view"
```

---

### Task 6.2: Hook InviteBanner to ContentView + auto-join on accept

**Files:**
- Modify: `PeerDrop/UI/ContentView.swift:29-68` (add overlay)
- Modify: `PeerDrop/Core/ConnectionManager.swift:1704-1715` (add `acceptRelayInvite` method)

**Step 1: Add `acceptRelayInvite` to ConnectionManager**

Insert after line 1704 (MARK: Relay Connection) in ConnectionManager.swift:

```swift
/// Accept a relay invite — creates signaling and joins as the answerer.
func acceptRelayInvite(_ invite: RelayInvite) {
    let baseURL = UserDefaults.standard.string(forKey: "peerDropWorkerURL")
        .flatMap(URL.init(string:))
        ?? URL(string: "https://peerdrop-signal.hanfourhuang.workers.dev")!
    let signaling = WorkerSignaling(baseURL: baseURL)
    Task {
        do {
            try await self.startWorkerRelayAsJoinerWithToken(
                roomCode: invite.roomCode,
                roomToken: invite.roomToken,
                signaling: signaling
            )
        } catch {
            ErrorReporter.report(
                error: error.localizedDescription,
                context: "invite.accept",
                extras: ["roomCode": invite.roomCode, "senderId": invite.senderId]
            )
        }
    }
}
```

**Step 2: Add token-aware joiner variant**

Also in ConnectionManager.swift (near line 1866 where startWorkerRelayAsJoiner lives), add:

```swift
/// Joiner flow for invite-driven connections — uses the roomToken from the invite
/// instead of racing ICE→token fetch. This is the fix for NSURLErrorDomain -1011.
func startWorkerRelayAsJoinerWithToken(roomCode: String, roomToken: String, signaling: WorkerSignaling) async throws {
    logger.info("Accepting invite — joining room \(roomCode) with token")
    let generation = UUID()
    connectionGeneration = generation
    forceTransitionToRequesting()

    // Open WebSocket FIRST with the invite-provided token (no race).
    signaling.joinRoom(code: roomCode, token: roomToken)

    // Fetch ICE in parallel; fall back to STUN if fails.
    let iceResult = try? await signaling.requestICECredentials(roomCode: roomCode)

    // Rest of joiner flow mirrors startWorkerRelayAsJoiner from line 1866.
    // Extract the common body into a private helper method for DRY.
    try await self.completeJoinerHandshake(
        roomCode: roomCode,
        signaling: signaling,
        iceResult: iceResult,
        generation: generation
    )
}
```

> **NOTE to implementer:** Extract the existing body of `startWorkerRelayAsJoiner` (after the ICE request) into a private `completeJoinerHandshake` helper so both the code-entry and invite-entry paths share the logic. Do NOT duplicate the 200 lines of WebRTC setup.

**Step 3: Overlay InviteBanner in ContentView**

Find the main ZStack or root view in ContentView (around lines 29-68). Add `@EnvironmentObject var inboxService: InboxService` at the top, and a `@StateObject` reference to `PushNotificationManager.shared`.

Add a VStack overlay at the top:

```swift
.overlay(alignment: .top) {
    if let invite = currentInvite {
        InviteBanner(
            invite: invite,
            onAccept: {
                connectionManager.acceptRelayInvite(invite)
                currentInvite = nil
            },
            onDecline: { currentInvite = nil }
        )
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.spring(duration: 0.3), value: currentInvite)
    }
}
.onReceive(inboxService.$receivedInvite.compactMap { $0 }) { currentInvite = $0 }
.onReceive(PushNotificationManager.shared.$receivedInvite.compactMap { $0 }) { currentInvite = $0 }
```

Where `currentInvite` is `@State var currentInvite: RelayInvite?`.

**Step 4: Build**

```bash
xcodegen generate
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet
```
Expected: BUILD SUCCEEDED.

**Step 5: Commit**

```bash
git add PeerDrop/Core/ConnectionManager.swift PeerDrop/UI/ContentView.swift
git commit -m "feat(ios): show InviteBanner and auto-join on accept (token from invite fixes -1011)"
```

---

## Phase 7 — iOS: Creator-side Device Picker + Invite Send

### Task 7.1: Send-invite helper on WorkerSignaling

**Files:**
- Modify: `PeerDrop/Transport/WorkerSignaling.swift` (add method after createRoom)

**Step 1: Add method**

After `createRoom()` (around line 88), add:

```swift
/// Send a relay invite to the given device. Creator-side only.
func sendInvite(
    toDeviceId deviceId: String,
    roomCode: String,
    roomToken: String,
    senderName: String,
    senderId: String
) async throws {
    let url = baseURL.appendingPathComponent("v2/invite/\(deviceId)")
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let body: [String: String] = [
        "roomCode": roomCode,
        "roomToken": roomToken,
        "senderName": senderName,
        "senderId": senderId,
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        let body = String(data: data, encoding: .utf8) ?? ""
        logger.error("Invite failed: \((response as? HTTPURLResponse)?.statusCode ?? -1) \(body)")
        throw WorkerSignalingError.webSocketError
    }
}
```

**Step 2: Commit**

```bash
git add PeerDrop/Transport/WorkerSignaling.swift
git commit -m "feat(ios): add sendInvite to WorkerSignaling"
```

---

### Task 7.2: Extend DeviceRecord with deviceId field

**Files:**
- Modify: `PeerDrop/Core/DeviceRecord.swift:9-35`
- Test: `PeerDropTests/DeviceRecordTests.swift` (if exists, add; else create)

**Step 1: Add `peerDeviceId` to the struct**

Inside the struct (at line 18 area, after certificateFingerprint):

```swift
var peerDeviceId: String?  // UUID of the peer device — used for invite routing
```

Also update any init or Codable handling — since Swift Codable with Optional new field should be backward-compatible.

**Step 2: Write a round-trip test**

```swift
func test_deviceRecord_encodesDecodesNewField() throws {
    let record = DeviceRecord(
        id: "test",
        displayName: "Test",
        sourceType: "relay",
        peerDeviceId: "ABCDEF-1234"
        // ... other required fields ...
    )
    let data = try JSONEncoder().encode(record)
    let back = try JSONDecoder().decode(DeviceRecord.self, from: data)
    XCTAssertEqual(back.peerDeviceId, "ABCDEF-1234")
}
```

**Step 3: Build + test**

```bash
xcodegen generate
xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/DeviceRecordTests
```
Expected: PASS.

**Step 4: Commit**

```bash
git add PeerDrop/Core/DeviceRecord.swift PeerDropTests/DeviceRecordTests.swift
git commit -m "feat(ios): add peerDeviceId to DeviceRecord for invite routing"
```

---

### Task 7.3: Exchange deviceId on first relay connection

**Files:**
- Modify: `PeerDrop/Core/ConnectionManager.swift:2013-2070` (completeRelayConnection — extend handshake to include deviceId swap)

**Step 1: Send a "device-id" message on DataChannel open**

In `startRelayHandshake` (around line 2086-2096, Task inside), after the existing HELLO send, add a companion `{"type":"device-id","id":"..."}` send. Receive handler parses and stores into DeviceRecord.

**Step 2: On receive side**

When the `device-id` message arrives (in the message handler inside startRelayHandshake or its receive loop — find where HELLO is consumed), extract the remote deviceId and update the matching DeviceRecord:

```swift
Task { @MainActor in
    await self.deviceRecordStore.updatePeerDeviceId(for: peerID, deviceId: remoteDeviceId)
}
```

**Step 3: Add helper to DeviceRecordStore**

Edit `PeerDrop/Core/DeviceRecordStore.swift` — add:

```swift
func updatePeerDeviceId(for recordId: String, deviceId: String) {
    guard var record = records[recordId] else { return }
    record.peerDeviceId = deviceId
    records[recordId] = record
    persist()
}
```

**Step 4: Test the exchange manually**

Skip a unit test here (requires full WebRTC mocking — low ROI). Rely on integration smoke test in Phase 8.

**Step 5: Build + commit**

```bash
xcodegen generate
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet
git add PeerDrop/Core/ConnectionManager.swift PeerDrop/Core/DeviceRecordStore.swift project.yml PeerDrop.xcodeproj
git commit -m "feat(ios): exchange deviceId on relay handshake for future invites"
```

---

### Task 7.4: DevicePickerView + integrate into RelayConnectView

**Files:**
- Create: `PeerDrop/UI/Relay/DevicePickerView.swift`
- Modify: `PeerDrop/UI/Relay/RelayConnectView.swift:128-132` (replace or supplement "Create Room" flow)

**Step 1: Write DevicePickerView**

```swift
import SwiftUI

struct DevicePickerView: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    @Environment(\.dismiss) var dismiss

    @State private var availableDevices: [DeviceRecord] = []
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        NavigationView {
            List {
                Section("Invite a known device") {
                    if availableDevices.isEmpty {
                        Text("No known devices yet. Share a room code manually for the first connection.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(availableDevices) { device in
                        Button {
                            Task { await invite(device) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(device.displayName).font(.body)
                                    if let peerId = device.peerDeviceId {
                                        Text(peerId.prefix(8) + "...")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    } else {
                                        Text("Device ID not yet known")
                                            .font(.caption2).foregroundStyle(.orange)
                                    }
                                }
                                Spacer()
                                if busy { ProgressView() }
                            }
                        }
                        .disabled(device.peerDeviceId == nil || busy)
                    }
                }
                if let errorText {
                    Section { Text(errorText).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Invite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { refresh() }
        }
    }

    private func refresh() {
        availableDevices = connectionManager.deviceRecordStore.allRecords()
            .filter { $0.peerDeviceId != nil }
            .sorted { $0.lastConnected > $1.lastConnected }
    }

    private func invite(_ device: DeviceRecord) async {
        guard let peerDeviceId = device.peerDeviceId else { return }
        busy = true
        errorText = nil
        defer { busy = false }
        do {
            let baseURL = URL(string: UserDefaults.standard.string(forKey: "peerDropWorkerURL")
                ?? "https://peerdrop-signal.hanfourhuang.workers.dev")!
            let signaling = WorkerSignaling(baseURL: baseURL)
            let room = try await signaling.createRoom()
            guard let roomToken = room.roomToken else {
                errorText = "Server did not return room token"
                return
            }
            let senderName = UIDevice.current.name
            try await signaling.sendInvite(
                toDeviceId: peerDeviceId,
                roomCode: room.roomCode,
                roomToken: roomToken,
                senderName: senderName,
                senderId: DeviceIdentity.deviceId
            )
            // Start relay as creator
            await MainActor.run {
                connectionManager.startWorkerRelayAsCreator(
                    roomCode: room.roomCode,
                    roomToken: roomToken,
                    signaling: signaling
                )
                dismiss()
            }
        } catch {
            errorText = error.localizedDescription
        }
    }
}
```

**Step 2: Add `allRecords()` helper to DeviceRecordStore if missing**

In DeviceRecordStore.swift:
```swift
func allRecords() -> [DeviceRecord] {
    Array(records.values)
}
```

**Step 3: Add "Invite Device" button to RelayConnectView**

In RelayConnectView.swift, near existing Create Room / Join Room buttons (lines 128-140), add an "Invite Device" button that presents `DevicePickerView` as a sheet.

```swift
@State private var showDevicePicker = false

Button {
    showDevicePicker = true
} label: {
    Label("Invite Device", systemImage: "person.crop.circle.badge.plus")
        .font(.body).bold()
        .frame(maxWidth: .infinity)
        .padding().background(.blue, in: RoundedRectangle(cornerRadius: 12))
        .foregroundStyle(.white)
}
.sheet(isPresented: $showDevicePicker) {
    DevicePickerView().environmentObject(connectionManager)
}
```

**Step 4: Build**

```bash
xcodegen generate
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet
```
Expected: BUILD SUCCEEDED.

**Step 5: Commit**

```bash
git add PeerDrop/UI/Relay/DevicePickerView.swift PeerDrop/UI/Relay/RelayConnectView.swift PeerDrop/Core/DeviceRecordStore.swift project.yml PeerDrop.xcodeproj
git commit -m "feat(ios): DevicePickerView for Creator-side auto-invite flow"
```

---

## Phase 8 — iOS: WebSocket Retry + Pre-flight

### Task 8.1: Add WebSocket retry logic in WorkerSignaling.joinRoom

**Files:**
- Modify: `PeerDrop/Transport/WorkerSignaling.swift:91-104`

**Step 1: Extend joinRoom to track retries**

Replace the current method with:

```swift
func joinRoom(code: String, token: String? = nil, retryCount: Int = 0) {
    var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
    components.scheme = baseURL.scheme == "https" ? "wss" : "ws"
    components.path = "/room/\(code)"
    if let token {
        components.queryItems = [URLQueryItem(name: "token", value: token)]
    }
    guard let wsURL = components.url else { return }

    webSocketTask = session.webSocketTask(with: wsURL)
    webSocketTask?.resume()
    logger.info("WebSocket connecting to room: \(code) (attempt \(retryCount + 1))")
    self.currentRetryCount = retryCount
    self.currentRoomCode = code
    self.currentRoomToken = token
    startReceiving()
}

// Add properties:
private var currentRetryCount = 0
private var currentRoomCode: String?
private var currentRoomToken: String?
private let maxRetries = 2
```

**Step 2: Intercept -1011 in startReceiving catch block**

At the `catch` block in `startReceiving` (around line 220-226), modify:

```swift
} catch {
    if !Task.isCancelled {
        let nsError = error as NSError
        logger.error("WebSocket receive error: \(error.localizedDescription) domain=\(nsError.domain) code=\(nsError.code)")

        // Retry on -1011 (bad server response) up to maxRetries
        if nsError.domain == NSURLErrorDomain && nsError.code == -1011
           && self?.currentRetryCount ?? maxRetries < self?.maxRetries ?? 0 {
            let next = (self?.currentRetryCount ?? 0) + 1
            guard let code = self?.currentRoomCode else {
                self?.onError?(error); break
            }
            let token = self?.currentRoomToken
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await MainActor.run {
                self?.joinRoom(code: code, token: token, retryCount: next)
            }
            return
        }

        self?.onError?(error)
    }
    break
}
```

**Step 3: Build**

```bash
xcodegen generate
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -quiet
```
Expected: BUILD SUCCEEDED.

**Step 4: Commit**

```bash
git add PeerDrop/Transport/WorkerSignaling.swift
git commit -m "fix(ios): retry WebSocket 2× on NSURLErrorDomain -1011"
```

---

## Phase 9 — End-to-End Device Test

### Task 9.1: Build release & install on two physical devices

Since this feature fundamentally requires two networked iPhones + real APNs, no simulator test can validate it. Instead:

**Step 1: Archive + install via TestFlight OR direct install**

User installs the build on Device A (Creator) and Device B (Joiner).

**Step 2: Smoke test — first-time connection (manual code entry)**

1. On Device A: tap Relay → Create Room → receive roomCode, shared manually.
2. On Device B: tap Relay → Join Room → enter roomCode.
3. Verify P2P connects within 30 seconds.
4. Verify both devices exchange deviceId via handshake (check `DeviceRecordStore` persistence — can add a debug menu log).
5. Confirm `/debug/reports` shows no `relay.joiner.webSocket` error.

**Step 3: Smoke test — invite flow (post-first-connection)**

1. On Device A: tap Relay → Invite Device → select Device B from list.
2. Device B (foreground): Banner slides in within ~1 second.
3. Tap Accept. P2P should connect.
4. Device B (background): lock device → repeat from Device A. Verify APNs notification arrives. Tap notification → app opens → auto-joins.

**Step 4: If failures occur**

Fetch server-side WebSocket diagnostic logs:

```bash
TOKEN=$(grep oauth_token /Users/hanfourmini/Library/Preferences/.wrangler/config/default.toml | sed 's/.*= "//;s/"//')
curl -s "https://api.cloudflare.com/client/v4/accounts/22d9d417c1d3ab5d72aa9aedc0cc183c/storage/kv/namespaces/376d9f22d4c743bfb1509b814087192c/keys?prefix=wslog:&limit=20" -H "Authorization: Bearer $TOKEN" \
  | python3 -c "import sys,json; data=json.load(sys.stdin); [print(k['name']) for k in data['result']]"
```

Then fetch each log entry and inspect for `reason`, `providedToken`, `expectedTokenHash` to pinpoint the exact failure cause.

**No commit** — purely validation phase. If new bugs found, create follow-up tasks.

---

## Rollback Plan

If anything in Phase 3 (APNs) or later breaks production:

```bash
cd cloudflare-worker
git checkout HEAD~N src/index.ts src/apns.ts wrangler.toml   # N = number of post-Phase-2 commits
npx wrangler deploy
```

iOS regressions: users can disable by flipping the feature via a remote flag (future work) OR you can revert via `git revert <commit>` + new TestFlight build. Phase 1 fixes (TTL, logging) are independently safe and should stay.
