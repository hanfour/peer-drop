# v3.3 Cross-Network Connection Experience — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ship v3.3 with full-connection telemetry, contextual guidance UI, manual tailnet peer discovery, and ICE configuration hardening — all gated on the design at `docs/plans/2026-04-22-crossnet-v33-design.md`.

**Architecture:** Four modules shipping together — `ConnectionMetrics` (iOS actor + Worker endpoints), `ICEConfigurationProvider` enhancements (TURN-over-TLS, candidate pool, phase deadlines), `TailnetPeerStore` (persistent IP list + 60 s probe + auto-reciprocal add), `ConnectionContext` + `GuidanceCard` (decision hub + single contextual UI). All communicate via existing MVVM patterns; metrics feed ConnectionContext's failure-rate signal.

**Tech Stack:** Swift 5.9 / SwiftUI / `@preconcurrency` WebRTC 125.0.0 / `NWConnection` / `URLSessionWebSocketTask` / Cloudflare Workers (TypeScript) / Durable Objects / KV.

**Reference Document:** `docs/plans/2026-04-22-crossnet-v33-design.md`

---

## Phase 1 — Worker: Telemetry Infrastructure

Ship the Worker side first so iOS has somewhere to send data when Phase 2 lands.

### Task 1.1: Add METRICS KV namespace + ANALYTICS_KEY secret

**Files:**
- Modify: `cloudflare-worker/wrangler.toml`
- Modify: `cloudflare-worker/src/index.ts:13-25` (Env interface)

**Step 1: Create KV namespace via wrangler**

```bash
cd cloudflare-worker
npx wrangler kv namespace create METRICS
```
Copy the returned `id` into `wrangler.toml`:

```toml
[[kv_namespaces]]
binding = "METRICS"
id = "<returned-id>"
```

**Step 2: Update Env interface**

Append to `Env`:

```typescript
METRICS: KVNamespace;
ANALYTICS_KEY: string;
```

**Step 3: Create ANALYTICS_KEY secret**

```bash
openssl rand -hex 32 | npx wrangler secret put ANALYTICS_KEY
```
Store the same value in your password manager — you will need it for Phase 1.5 aggregate queries.

**Step 4: Deploy and verify bindings**

Run `cd cloudflare-worker && npx wrangler deploy` and confirm the bindings table lists both `METRICS` (KV) and `ANALYTICS_KEY` (secret).

**Step 5: Commit**

```bash
git add cloudflare-worker/wrangler.toml cloudflare-worker/src/index.ts
git commit -m "infra(worker): add METRICS KV namespace and ANALYTICS_KEY secret"
```

---

### Task 1.2: Add `POST /debug/metric` endpoint (no aggregation yet)

**Files:**
- Modify: `cloudflare-worker/src/index.ts` (insert route near existing `/debug/report`, around line 284)

**Step 1: Add the route**

```typescript
// POST /debug/metric — ingest connection telemetry (API_KEY required)
if (path === "/debug/metric" && request.method === "POST") {
  if (!env.API_KEY || request.headers.get("X-API-Key") !== env.API_KEY) {
    return jsonResponse({ error: "Unauthorized" }, 401);
  }
  // Payload size limit: 4 KB
  const body = await request.text();
  if (body.length > 4 * 1024) {
    return jsonResponse({ error: "Payload too large", size: body.length }, 413);
  }
  let parsed: Record<string, unknown>;
  try { parsed = JSON.parse(body); } catch { return jsonResponse({ error: "Invalid JSON" }, 400); }
  const dateKey = new Date().toISOString().slice(0, 10); // YYYY-MM-DD
  const metricId = `metric:${dateKey}:${crypto.randomUUID()}`;
  await env.METRICS.put(metricId, JSON.stringify({
    ...parsed,
    ingestedAt: new Date().toISOString(),
    ip: clientIP,
  }), { expirationTtl: 14 * 86400 });
  return jsonResponse({ ok: true, id: metricId }, 201);
}
```

**Step 2: Deploy**

```bash
cd cloudflare-worker && npx wrangler deploy
```

**Step 3: Smoke test — valid payload**

```bash
API_KEY=$(grep "PEERDROP_WORKER_API_KEY" "../Secrets.xcconfig" | tr '=' '\n' | tail -1 | xargs)
curl -s -X POST https://peerdrop-signal.hanfourhuang.workers.dev/debug/metric \
  -H "Content-Type: application/json" \
  -H "X-API-Key: $API_KEY" \
  -d '{"connectionType":"localBonjour","role":"initiator","outcome":"success","durationMs":1234}'
```
Expected: `{"ok":true,"id":"metric:2026-04-22:..."}`

**Step 4: Smoke test — 413 on oversized payload**

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://peerdrop-signal.hanfourhuang.workers.dev/debug/metric \
  -H "Content-Type: application/json" \
  -H "X-API-Key: $API_KEY" \
  -d "$(python3 -c 'print("x"*5000)')"
```
Expected: `413`

**Step 5: Smoke test — 401 on missing API key**

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://peerdrop-signal.hanfourhuang.workers.dev/debug/metric \
  -H "Content-Type: application/json" -d '{}'
```
Expected: `401`

**Step 6: Commit**

```bash
git add cloudflare-worker/src/index.ts
git commit -m "feat(worker): add /debug/metric ingest with 4 KB limit"
```

---

### Task 1.3: Add `GET /config/metrics` (remote circuit breaker)

**Files:**
- Modify: `cloudflare-worker/src/index.ts` (insert near `/debug/metric`)

**Step 1: Add the route**

```typescript
// GET /config/metrics — remote circuit breaker (no auth, public)
if (path === "/config/metrics" && request.method === "GET") {
  const raw = await env.METRICS.get("config:metrics");
  const parsed = raw ? JSON.parse(raw) : { sampleRate: 1.0, enabled: true };
  return jsonResponse(parsed);
}
```

**Step 2: Seed initial config**

```bash
cd cloudflare-worker
echo '{"sampleRate":1.0,"enabled":true}' | npx wrangler kv key put --binding METRICS --remote config:metrics
```

**Step 3: Deploy and verify**

```bash
cd cloudflare-worker && npx wrangler deploy
curl -s https://peerdrop-signal.hanfourhuang.workers.dev/config/metrics
```
Expected: `{"sampleRate":1,"enabled":true}`

**Step 4: Commit**

```bash
git add cloudflare-worker/src/index.ts
git commit -m "feat(worker): add /config/metrics remote circuit breaker"
```

---

### Task 1.4: Add `GET /debug/metrics/stats` (aggregate query)

**Files:**
- Modify: `cloudflare-worker/src/index.ts`

**Step 1: Add the route**

```typescript
// GET /debug/metrics/stats?range=24h|7d — aggregate metrics (ANALYTICS_KEY required)
if (path === "/debug/metrics/stats" && request.method === "GET") {
  if (!env.ANALYTICS_KEY || request.headers.get("X-API-Key") !== env.ANALYTICS_KEY) {
    return jsonResponse({ error: "Unauthorized" }, 401);
  }
  const range = url.searchParams.get("range") || "24h";
  const daysBack = range === "7d" ? 7 : range === "30d" ? 30 : 1;
  const prefixes: string[] = [];
  for (let i = 0; i < daysBack; i++) {
    const d = new Date(Date.now() - i * 86400_000);
    prefixes.push(`metric:${d.toISOString().slice(0, 10)}:`);
  }
  // Collect up to 5000 metrics across the window.
  const metrics: Record<string, unknown>[] = [];
  for (const prefix of prefixes) {
    const list = await env.METRICS.list({ prefix, limit: 1000 });
    for (const key of list.keys) {
      if (metrics.length >= 5000) break;
      const raw = await env.METRICS.get(key.name);
      if (raw) metrics.push(JSON.parse(raw));
    }
    if (metrics.length >= 5000) break;
  }
  // Aggregate
  const byType: Record<string, { success: number; failure: number; abandoned: number; durations: number[] }> = {};
  const candidateUse: Record<string, number> = {};
  const failureReasons: Record<string, number> = {};
  for (const m of metrics) {
    const t = String(m["connectionType"] ?? "unknown");
    byType[t] ??= { success: 0, failure: 0, abandoned: 0, durations: [] };
    const outcome = (m["outcome"] as any)?.type ?? m["outcome"];
    if (outcome === "success") byType[t].success++;
    else if (outcome === "abandoned") byType[t].abandoned++;
    else byType[t].failure++;
    if (typeof m["durationMs"] === "number") byType[t].durations.push(m["durationMs"] as number);
    const used = (m["iceStats"] as any)?.candidatesUsed;
    if (used) candidateUse[used] = (candidateUse[used] ?? 0) + 1;
    const reason = (m["outcome"] as any)?.reason ?? (outcome === "success" ? null : String(outcome));
    if (reason && reason !== "success") failureReasons[reason] = (failureReasons[reason] ?? 0) + 1;
  }
  const stats = {
    range, total: metrics.length,
    byType: Object.fromEntries(Object.entries(byType).map(([k, v]) => {
      const d = v.durations.sort((a, b) => a - b);
      return [k, { success: v.success, failure: v.failure, abandoned: v.abandoned,
                    p50: d[Math.floor(d.length * 0.5)] ?? null,
                    p95: d[Math.floor(d.length * 0.95)] ?? null }];
    })),
    candidateUse, failureReasons,
  };
  return jsonResponse(stats);
}
```

**Step 2: Deploy**

```bash
cd cloudflare-worker && npx wrangler deploy
```

**Step 3: Smoke test**

```bash
ANALYTICS_KEY="<paste from password manager>"
curl -s -H "X-API-Key: $ANALYTICS_KEY" "https://peerdrop-signal.hanfourhuang.workers.dev/debug/metrics/stats?range=24h" | python3 -m json.tool
```
Expected: JSON with `total`, `byType`, `candidateUse`, `failureReasons` (mostly empty on day-one).

**Step 4: Commit**

```bash
git add cloudflare-worker/src/index.ts
git commit -m "feat(worker): add /debug/metrics/stats aggregate query"
```

---

## Phase 2 — iOS: `ConnectionMetrics` actor

### Task 2.1: Data models with Codable round-trip tests

**Files:**
- Create: `PeerDrop/Core/ConnectionMetric.swift`
- Create: `PeerDropTests/ConnectionMetricTests.swift`

**Step 1: Write failing test first**

```swift
import XCTest
@testable import PeerDrop

final class ConnectionMetricTests: XCTestCase {
    func test_metricRoundTripsThroughCodable() throws {
        let m = ConnectionMetric(
            id: "abc", timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            connectionType: .relayWorker, role: .joiner,
            outcome: .success, durationMs: 1234,
            iceStats: ConnectionMetric.ICEStats(
                candidatesGathered: [.host, .srflx, .relay],
                candidatesUsed: .relay,
                srflxGatherOrder: 1, relayGatherOrder: 2,
                firstConnectedMs: 900,
                phase1ConnectedMs: nil,
                phase2ConnectedMs: 1200,
                ipv6CandidateGathered: true,
                ipv6Connected: false),
            platform: "ios", appVersion: "3.3.0",
            networkType: .wifi, hasTailscale: false, hasIPv6: true)
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(ConnectionMetric.self, from: data)
        XCTAssertEqual(back.id, m.id)
        XCTAssertEqual(back.iceStats?.candidatesGathered, [.host, .srflx, .relay])
        XCTAssertEqual(back.iceStats?.candidatesUsed, .relay)
    }

    func test_outcome_failureSerializesWithReason() throws {
        let m = ConnectionMetric.withOutcome(.failure(reason: "timeout"))
        let data = try JSONEncoder().encode(m)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let outcome = json["outcome"] as! [String: Any]
        XCTAssertEqual(outcome["type"] as? String, "failure")
        XCTAssertEqual(outcome["reason"] as? String, "timeout")
    }
}

// Test helper
extension ConnectionMetric {
    static func withOutcome(_ o: Outcome) -> ConnectionMetric {
        .init(id: "x", timestamp: Date(), connectionType: .relayWorker, role: .joiner,
              outcome: o, durationMs: 0, iceStats: nil, platform: "ios",
              appVersion: "3.3.0", networkType: .unknown, hasTailscale: false, hasIPv6: false)
    }
}
```

**Step 2: Run — expect FAIL** (type not found)

```bash
xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/ConnectionMetricTests
```

**Step 3: Write the model**

```swift
import Foundation

struct ConnectionMetric: Codable, Equatable {
    let id: String
    let timestamp: Date
    let connectionType: ConnectionType
    let role: Role
    let outcome: Outcome
    let durationMs: Int
    let iceStats: ICEStats?
    let platform: String
    let appVersion: String
    let networkType: NetworkType
    let hasTailscale: Bool
    let hasIPv6: Bool

    enum ConnectionType: String, Codable { case localBonjour, relayWorker, manualTailnet, manualIP }
    enum Role: String, Codable { case initiator, joiner }
    enum NetworkType: String, Codable { case wifi, cellular, wifi_hotspot, ethernet, unknown }
    enum CandidateType: String, Codable { case host, srflx, relay, prflx }

    enum Outcome: Codable, Equatable {
        case success
        case failure(reason: String)
        case abandoned

        enum CodingKeys: String, CodingKey { case type, reason }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .success: try c.encode("success", forKey: .type)
            case .failure(let r): try c.encode("failure", forKey: .type); try c.encode(r, forKey: .reason)
            case .abandoned: try c.encode("abandoned", forKey: .type)
            }
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decode(String.self, forKey: .type) {
            case "success": self = .success
            case "abandoned": self = .abandoned
            default: self = .failure(reason: (try? c.decode(String.self, forKey: .reason)) ?? "unknown")
            }
        }
    }

    struct ICEStats: Codable, Equatable {
        let candidatesGathered: [CandidateType]
        let candidatesUsed: CandidateType?
        let srflxGatherOrder: Int?
        let relayGatherOrder: Int?
        let firstConnectedMs: Int?
        let phase1ConnectedMs: Int?
        let phase2ConnectedMs: Int?
        let ipv6CandidateGathered: Bool
        let ipv6Connected: Bool
    }
}
```

**Step 4: Regenerate Xcode project + run tests**

```bash
cd "/Volumes/SATECHI DISK Media/UserFolders/Projects/applications/peer-drop"
xcodegen generate
xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/ConnectionMetricTests
```
Expected: 2 tests PASS.

**Step 5: Commit**

```bash
git add PeerDrop/Core/ConnectionMetric.swift PeerDropTests/ConnectionMetricTests.swift project.yml PeerDrop.xcodeproj
git commit -m "feat(ios): add ConnectionMetric data model with Codable round-trip"
```

---

### Task 2.2: `ConnectionMetrics` actor with Token lifecycle

**Files:**
- Create: `PeerDrop/Core/ConnectionMetrics.swift`
- Create: `PeerDropTests/ConnectionMetricsTests.swift`

**Step 1: Write failing tests (buffer + flush behaviour)**

```swift
import XCTest
@testable import PeerDrop

@MainActor
final class ConnectionMetricsTests: XCTestCase {
    func test_tokenFinalizedWithSuccess_recordsMetric() async {
        let m = ConnectionMetrics(flushOnCount: 1)
        let token = await m.begin(type: .localBonjour, role: .initiator)
        await m.recordConnected(token, used: .host)
        let pending = await m.pendingCount
        XCTAssertEqual(pending, 0) // flushed immediately due to flushOnCount=1
        XCTAssertEqual(await m.lastFlushedCount, 1)
    }

    func test_tokenDeinitsWithoutFinalize_recordsAbandoned() async {
        let m = ConnectionMetrics(flushOnCount: 1)
        do {
            let _ = await m.begin(type: .relayWorker, role: .joiner)
        }
        // Allow actor to process deinit callback
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(await m.lastFlushedCount, 1)
        let last = await m.lastFlushedMetric
        if case .abandoned = last?.outcome {} else { XCTFail("Expected .abandoned") }
    }
}
```

**Step 2: Run — expect FAIL**

**Step 3: Implement**

```swift
import Foundation
import UIKit
import os.log

actor ConnectionMetrics {
    static let shared = ConnectionMetrics()

    private let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "ConnectionMetrics")
    private var buffer: [ConnectionMetric] = []
    private let flushThreshold: Int
    private var remoteConfig: RemoteConfig = .default
    private(set) var lastFlushedCount: Int = 0
    private(set) var lastFlushedMetric: ConnectionMetric?

    init(flushOnCount: Int = 50) { self.flushThreshold = flushOnCount }

    var pendingCount: Int { buffer.count }

    struct RemoteConfig: Codable { let sampleRate: Double; let enabled: Bool
        static let `default` = RemoteConfig(sampleRate: 1.0, enabled: true)
    }

    final class Token {
        let id = UUID().uuidString
        let startedAt = Date()
        let type: ConnectionMetric.ConnectionType
        let role: ConnectionMetric.Role
        var gathered: [ConnectionMetric.CandidateType] = []
        var srflxOrder: Int?; var relayOrder: Int?
        var phase1Ms: Int?; var phase2Ms: Int?
        var ipv6Gathered: Bool = false; var ipv6Connected: Bool = false
        var finalized: Bool = false
        var onDeinit: ((Token) -> Void)?
        init(type: ConnectionMetric.ConnectionType, role: ConnectionMetric.Role) {
            self.type = type; self.role = role
        }
        deinit { if !finalized { onDeinit?(self) } }
    }

    func begin(type: ConnectionMetric.ConnectionType, role: ConnectionMetric.Role) -> Token {
        let t = Token(type: type, role: role)
        t.onDeinit = { [weak self] tok in
            Task { await self?.recordAbandoned(tok) }
        }
        return t
    }

    func recordICEGather(_ token: Token, candidate: ConnectionMetric.CandidateType, order: Int, isIPv6: Bool = false) {
        token.gathered.append(candidate)
        if candidate == .srflx, token.srflxOrder == nil { token.srflxOrder = order }
        if candidate == .relay, token.relayOrder == nil { token.relayOrder = order }
        if isIPv6 { token.ipv6Gathered = true }
    }

    func recordConnected(_ token: Token, used: ConnectionMetric.CandidateType, ipv6Connected: Bool = false) {
        token.finalized = true
        token.ipv6Connected = ipv6Connected
        finalize(token, outcome: .success, used: used)
    }

    func recordFailure(_ token: Token, reason: String) {
        token.finalized = true
        finalize(token, outcome: .failure(reason: reason), used: nil)
    }

    private func recordAbandoned(_ token: Token) {
        guard !token.finalized else { return }
        finalize(token, outcome: .abandoned, used: nil)
    }

    private func finalize(_ token: Token, outcome: ConnectionMetric.Outcome, used: ConnectionMetric.CandidateType?) {
        let stats = ConnectionMetric.ICEStats(
            candidatesGathered: token.gathered, candidatesUsed: used,
            srflxGatherOrder: token.srflxOrder, relayGatherOrder: token.relayOrder,
            firstConnectedMs: nil,
            phase1ConnectedMs: token.phase1Ms, phase2ConnectedMs: token.phase2Ms,
            ipv6CandidateGathered: token.ipv6Gathered, ipv6Connected: token.ipv6Connected)
        let durationMs = Int(Date().timeIntervalSince(token.startedAt) * 1000)
        let metric = ConnectionMetric(
            id: token.id, timestamp: Date(),
            connectionType: token.type, role: token.role,
            outcome: outcome, durationMs: durationMs,
            iceStats: stats,
            platform: "ios",
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            networkType: .unknown, hasTailscale: false, hasIPv6: false)

        // Apply sampling
        guard remoteConfig.enabled,
              Double.random(in: 0..<1) < remoteConfig.sampleRate else { return }

        buffer.append(metric)
        lastFlushedMetric = metric
        lastFlushedCount += 1
        if buffer.count >= flushThreshold { Task { await flush() } }
    }

    func flush() async {
        let batch = buffer; buffer.removeAll(keepingCapacity: true)
        guard !batch.isEmpty else { return }
        // Stub: will be wired in Task 2.4
    }

    func updateRemoteConfig(_ cfg: RemoteConfig) { remoteConfig = cfg }
}
```

**Step 4: Run tests — expect PASS**

```bash
xcodegen generate
xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/ConnectionMetricsTests
```

**Step 5: Commit**

```bash
git add PeerDrop/Core/ConnectionMetrics.swift PeerDropTests/ConnectionMetricsTests.swift project.yml PeerDrop.xcodeproj
git commit -m "feat(ios): ConnectionMetrics actor with Token + deinit abandonment"
```

---

### Task 2.3: `ConnectionMetrics.flush()` HTTP POST implementation

**Files:**
- Modify: `PeerDrop/Core/ConnectionMetrics.swift` (extend `flush()`)

**Step 1: Replace the stubbed `flush()`**

```swift
func flush() async {
    let batch = buffer; buffer.removeAll(keepingCapacity: true)
    guard !batch.isEmpty else { return }

    let baseURL = UserDefaults.standard.string(forKey: "peerDropWorkerURL")
        ?? "https://peerdrop-signal.hanfourhuang.workers.dev"
    let apiKey = Bundle.main.object(forInfoDictionaryKey: "PeerDropWorkerAPIKey") as? String
    guard let apiKey else { return }
    guard let url = URL(string: "\(baseURL)/debug/metric") else { return }

    for metric in batch {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        req.timeoutInterval = 10
        do {
            req.httpBody = try JSONEncoder.iso8601().encode(metric)
            let (_, _) = try await URLSession.shared.data(for: req)
            // Drop on any non-201 — do NOT queue per design decision.
        } catch {
            logger.debug("metric flush failed: \(error.localizedDescription)")
        }
    }
}

private extension JSONEncoder {
    static func iso8601() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
}
```

**Step 2: Build — expect SUCCESS**

```bash
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest'
```

**Step 3: Commit**

```bash
git add PeerDrop/Core/ConnectionMetrics.swift
git commit -m "feat(ios): ConnectionMetrics.flush posts batch to /debug/metric"
```

---

### Task 2.4: Remote config fetch on app launch + every 6 hours

**Files:**
- Modify: `PeerDrop/Core/ConnectionMetrics.swift` (add `fetchRemoteConfig()`)
- Modify: `PeerDrop/App/PeerDropApp.swift:14-16` (trigger fetch)

**Step 1: Add fetch method**

```swift
func fetchRemoteConfig() async {
    let baseURL = UserDefaults.standard.string(forKey: "peerDropWorkerURL")
        ?? "https://peerdrop-signal.hanfourhuang.workers.dev"
    guard let url = URL(string: "\(baseURL)/config/metrics") else { return }
    var req = URLRequest(url: url); req.timeoutInterval = 5
    do {
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
        let cfg = try JSONDecoder().decode(RemoteConfig.self, from: data)
        self.remoteConfig = cfg
        if let encoded = try? JSONEncoder().encode(cfg) {
            UserDefaults.standard.set(encoded, forKey: "peerDropMetricsConfig")
        }
    } catch {
        // Fall back to cached
        if let cached = UserDefaults.standard.data(forKey: "peerDropMetricsConfig"),
           let cfg = try? JSONDecoder().decode(RemoteConfig.self, from: cached) {
            self.remoteConfig = cfg
        }
    }
}
```

**Step 2: Trigger in `PeerDropApp`**

Inside the existing `.task` block added in v3.2 (after `requestAuthorizationAndRegister`):

```swift
.task {
    await PushNotificationManager.shared.requestAuthorizationAndRegister()
    await ConnectionMetrics.shared.fetchRemoteConfig()
    // Re-fetch every 6 hours while foregrounded.
    while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 6 * 3600 * 1_000_000_000)
        await ConnectionMetrics.shared.fetchRemoteConfig()
    }
}
```

**Step 3: Build**

```bash
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest'
```

**Step 4: Commit**

```bash
git add PeerDrop/Core/ConnectionMetrics.swift PeerDrop/App/PeerDropApp.swift
git commit -m "feat(ios): ConnectionMetrics fetches remote config on launch + every 6h"
```

---

### Task 2.5: Wire metrics into `ConnectionManager` relay flows

**Files:**
- Modify: `PeerDrop/Core/ConnectionManager.swift:1713-2010` (creator + both joiner entry points)

**Step 1: In `startWorkerRelayAsCreator`, wrap with metrics**

Near the `Task {` at line ~1734, store a metrics token:

```swift
let metricsToken = await ConnectionMetrics.shared.begin(type: .relayWorker, role: .initiator)
```

At every `ErrorReporter.report(...)` call site and each final state transition, add a parallel metrics call. For successes, when transport transitions to `.ready` in `transport.onStateChange`:

```swift
Task { await ConnectionMetrics.shared.recordConnected(metricsToken, used: .relay) }
```

For failures (timeout, onError, dataChannel failed):

```swift
Task { await ConnectionMetrics.shared.recordFailure(metricsToken, reason: "creator.timeout") }
```

**Step 2: Do the same for `startWorkerRelayAsJoiner` and `startWorkerRelayAsJoinerWithToken`.** For the latter, `role: .joiner`.

**Step 3: Add ICE candidate reporting inside `client.onICECandidate`**

For each local candidate gathered, parse `candidate.sdp` to detect type (`typ host`, `typ srflx`, `typ relay`):

```swift
let type: ConnectionMetric.CandidateType
if candidate.sdp.contains("typ host") { type = .host }
else if candidate.sdp.contains("typ srflx") { type = .srflx }
else if candidate.sdp.contains("typ relay") { type = .relay }
else { type = .prflx }
let order = nextGatherOrder()
let isIPv6 = candidate.sdp.contains(":") && !candidate.sdp.contains(".")
Task { await ConnectionMetrics.shared.recordICEGather(metricsToken, candidate: type, order: order, isIPv6: isIPv6) }
```

Add `private var iceOrderCounter: Int = 0; private func nextGatherOrder() -> Int { iceOrderCounter += 1; return iceOrderCounter }` locally in each function scope.

**Step 4: Build + smoke test**

```bash
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest'
```

Manually verify on simulator: run app, attempt relay connection, inspect Worker `GET /debug/metrics/stats` shows at least 1 metric within 60 s.

**Step 5: Commit**

```bash
git add PeerDrop/Core/ConnectionManager.swift
git commit -m "feat(ios): wire ConnectionMetrics into relay creator/joiner flows"
```

---

### Task 2.6: Flush on scene background transition

**Files:**
- Modify: `PeerDrop/App/PeerDropApp.swift:88-101` (existing `onChange(of: scenePhase)`)

**Step 1: Add flush call in `.background` case**

```swift
.onChange(of: scenePhase) { newPhase in
    connectionManager.handleScenePhaseChange(newPhase)
    switch newPhase {
    case .background:
        inboxService.disconnect()
        Task { await ConnectionMetrics.shared.flush() }  // ← NEW
        try? PetStore().save(petEngine.pet)
        // ...
    case .active:
        inboxService.connect()
        petEngine.endLiveActivity()
    default: break
    }
}
```

**Step 2: Build + commit**

```bash
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest'
git add PeerDrop/App/PeerDropApp.swift
git commit -m "feat(ios): flush ConnectionMetrics on scene background"
```

---

## Phase 3 — ICE Enhancements

### Task 3.1: Worker returns TURN-over-TCP and TURN-over-TLS URLs

**Files:**
- Modify: `cloudflare-worker/src/index.ts:257-310` (ICE response builder)

**Step 1: Find the existing TURN response block** (around line 257 — the `turnResponse` JSON shape).

**Step 2: Extend returned URLs**

Wherever the response builds `iceServers`, produce three URLs per TURN entry:

```typescript
const turnURLs = [
  "turn:turn.cloudflare.com:3478?transport=udp",
  "turn:turn.cloudflare.com:3478?transport=tcp",
  "turns:turn.cloudflare.com:5349?transport=tcp",
];
return jsonResponse({
  iceServers: [
    { urls: ["stun:stun.cloudflare.com:3478", "stun:stun.l.google.com:19302"] },
    { urls: turnURLs, username: creds.username, credential: creds.credential },
  ],
  roomToken,
});
```

Keep the STUN-only fallback path unchanged.

**Step 3: Deploy + smoke test**

```bash
cd cloudflare-worker && npx wrangler deploy
curl -s -X POST https://peerdrop-signal.hanfourhuang.workers.dev/room/{fresh_code}/ice \
  -H "X-API-Key: $API_KEY" | python3 -m json.tool | head -30
```
Expected: `iceServers[1].urls` has 3 entries including `turns:`.

**Step 4: Commit**

```bash
git add cloudflare-worker/src/index.ts
git commit -m "feat(worker): include TURN over TCP + TLS in ICE response"
```

---

### Task 3.2: iOS `iceCandidatePoolSize = 2` + parse multi-URL TURN response

**Files:**
- Modify: `PeerDrop/Transport/ICEConfigurationProvider.swift`

**Step 1: Bump pool size**

```swift
static func defaultConfiguration() -> RTCConfiguration {
    let config = RTCConfiguration()
    config.iceServers = stunServers
    config.sdpSemantics = .unifiedPlan
    config.iceTransportPolicy = .all
    config.bundlePolicy = .maxBundle
    config.rtcpMuxPolicy = .require
    config.continualGatheringPolicy = .gatherContinually
    config.iceCandidatePoolSize = 2  // NEW
    return config
}

static func configuration(with credentials: ICECredentials) -> RTCConfiguration {
    let config = defaultConfiguration()
    config.iceServers = iceServers(from: credentials)
    return config
}
```

**Step 2: Ensure `ICECredentials.urls` is already `[String]`** (it is — no change needed).

**Step 3: Build + commit**

```bash
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest'
git add PeerDrop/Transport/ICEConfigurationProvider.swift
git commit -m "feat(ios): iceCandidatePoolSize=2 to pre-warm candidates"
```

---

### Task 3.3: Phase-1 / Phase-2 logical deadline in `completeJoinerHandshake`

**Files:**
- Modify: `PeerDrop/Core/ConnectionManager.swift` (`completeJoinerHandshake`, around line 1964-2083)

**Step 1: Add phase-aware state observer**

Replace the `transport.onStateChange` closure body. Keep existing structure but add phase tracking:

```swift
let handshakeStart = Date()
var phase = 1  // 1 = prefer direct, 2 = accept relay, 3 = give up

transport.onStateChange = { [weak self, weak signaling] state in
    guard let self, self.connectionGeneration == generation else { return }
    let elapsedMs = Int(Date().timeIntervalSince(handshakeStart) * 1000)
    Task { @MainActor in
        switch state {
        case .ready:
            // Record phase this succeeded in
            if phase == 1 {
                // Direct or relay both accepted in phase 1
            } else {
                // Phase 2 save — relay-rescue path
            }
            signaling?.disconnect()
            self.completeRelayConnection(transport: transport, roomCode: roomCode)
        case .failed(let error): // unchanged
        case .cancelled, .connecting: break
        }
    }
}

// Phase advancement timer (logical marker only, no restartIce)
Task { [weak self] in
    try? await Task.sleep(nanoseconds: 8_000_000_000)
    guard let self, self.connectionGeneration == generation else { return }
    if case .requesting = await self.state {
        phase = 2  // From now on, relay-pair arrivals become acceptable
        logger.info("Relay handshake phase 1 → 2 (direct not yet succeeded)")
    }
}

// Give up at 20 s (was 30 s)
Task { [weak self] in
    try? await Task.sleep(nanoseconds: 20_000_000_000)
    guard let self, self.connectionGeneration == generation else { return }
    if case .requesting = await self.state {
        ErrorReporter.report(error: "Relay connection timed out (phase 3)",
            context: "relay.joiner.timeout",
            extras: ["roomCode": roomCode, "step": "phase3Timeout"])
        self.transition(to: .failed(reason: "Relay connection timed out"))
    }
}
```

**NOTE:** The phase variable is read by the state observer but WebRTC's own ICE engine still prefers direct when possible — phase is only a logical marker for our metrics. Do NOT call `restartIce()`.

**Step 2: Record phase in metrics**

When `.ready` fires, pass `phase` into `recordConnected`:

```swift
if phase == 1 {
    token.phase1Ms = elapsedMs
} else {
    token.phase2Ms = elapsedMs
}
Task { await ConnectionMetrics.shared.recordConnected(metricsToken, used: .relay) }
```

(You will need to extend `Token` to expose `phase1Ms` / `phase2Ms` setters — already present from Task 2.2.)

**Step 3: Build**

```bash
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest'
```

**Step 4: Commit**

```bash
git add PeerDrop/Core/ConnectionManager.swift
git commit -m "feat(ios): phase-1/phase-2 logical deadlines in joiner handshake"
```

---

### Task 3.4: Network fingerprint + relay hints store

**Files:**
- Create: `PeerDrop/Core/NetworkFingerprint.swift`
- Create: `PeerDropTests/NetworkFingerprintTests.swift`

**Step 1: Write failing test**

```swift
import XCTest
@testable import PeerDrop

final class NetworkFingerprintTests: XCTestCase {
    func test_sameSubnetAndGateway_yieldsSameFingerprint() {
        let a = NetworkFingerprint.fingerprint(subnet: "192.168.1.0/24", gateway: "192.168.1.1")
        let b = NetworkFingerprint.fingerprint(subnet: "192.168.1.0/24", gateway: "192.168.1.1")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 8)
    }

    func test_differentGateway_yieldsDifferentFingerprint() {
        let a = NetworkFingerprint.fingerprint(subnet: "192.168.1.0/24", gateway: "192.168.1.1")
        let b = NetworkFingerprint.fingerprint(subnet: "192.168.1.0/24", gateway: "192.168.1.254")
        XCTAssertNotEqual(a, b)
    }
}
```

**Step 2: Run — expect FAIL**

**Step 3: Implement**

```swift
import Foundation
import CryptoKit

enum NetworkFingerprint {
    /// Stable 8-hex-char identifier for the current network, keyed by
    /// (subnet, gateway). Must be deterministic — used as UserDefaults key.
    static func fingerprint(subnet: String, gateway: String) -> String {
        let input = "\(subnet)|\(gateway)"
        let hash = SHA256.hash(data: Data(input.utf8))
        return hash.prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}

/// Tracks how often a given network fingerprint required phase-2 (relay)
/// rescue. After 3 consecutive phase-2 successes, skip P2P attempts.
final class RelayHintsStore {
    static let shared = RelayHintsStore()
    private let key = "peerDropRelayHints"
    private var hints: [String: Int] { get {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: Int]) ?? [:]
    } set {
        UserDefaults.standard.set(newValue, forKey: key)
    }}

    func shouldPreferRelay(fingerprint: String) -> Bool { (hints[fingerprint] ?? 0) >= 3 }

    func recordPhase2Save(fingerprint: String) {
        var h = hints; h[fingerprint] = (h[fingerprint] ?? 0) + 1; hints = h
    }

    func recordPhase1Success(fingerprint: String) {
        var h = hints; h[fingerprint] = 0; hints = h
    }
}
```

**Step 4: Run — expect PASS**

```bash
xcodegen generate
xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/NetworkFingerprintTests
```

**Step 5: Commit**

```bash
git add PeerDrop/Core/NetworkFingerprint.swift PeerDropTests/NetworkFingerprintTests.swift project.yml PeerDrop.xcodeproj
git commit -m "feat(ios): NetworkFingerprint + RelayHintsStore for adaptive ICE policy"
```

---

### Task 3.5: Consume RelayHintsStore in joiner flow

**Files:**
- Modify: `PeerDrop/Core/ConnectionManager.swift` (`completeJoinerHandshake`)

**Step 1: Get current fingerprint**

Add helper to ConnectionManager:

```swift
private func currentNetworkFingerprint() -> String {
    // Parse /proc-like: ifaddrs to find default gateway + subnet
    // Simplest: use the first en0/en1 with IPv4, derive /24 subnet
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return "unknown" }
    defer { freeifaddrs(ifaddr) }
    for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let i = ptr.pointee
        let name = String(cString: i.ifa_name)
        guard name == "en0" || name == "en1" || name.hasPrefix("bridge"),
              i.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        getnameinfo(i.ifa_addr, socklen_t(i.ifa_addr.pointee.sa_len),
                    &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        let ip = String(cString: host)
        let octets = ip.split(separator: ".")
        guard octets.count == 4 else { continue }
        let subnet = "\(octets[0]).\(octets[1]).\(octets[2]).0/24"
        let gateway = "\(octets[0]).\(octets[1]).\(octets[2]).1" // approximate
        return NetworkFingerprint.fingerprint(subnet: subnet, gateway: gateway)
    }
    return "unknown"
}
```

**Step 2: Apply hint at start of `completeJoinerHandshake`**

```swift
let fingerprint = currentNetworkFingerprint()
let preferRelay = RelayHintsStore.shared.shouldPreferRelay(fingerprint: fingerprint)
let config = iceResult?.credentials.map { ICEConfigurationProvider.configuration(with: $0) }
    ?? ICEConfigurationProvider.defaultConfiguration()
config.iceTransportPolicy = preferRelay ? .relay : .all
client.setup(with: config)
```

Update `DataChannelClient.setup(iceServers:)` to `setup(with:)` taking a full `RTCConfiguration`.

**Step 3: Record results back into store**

In the `.ready` handler:

```swift
if phase == 1 {
    RelayHintsStore.shared.recordPhase1Success(fingerprint: fingerprint)
} else {
    RelayHintsStore.shared.recordPhase2Save(fingerprint: fingerprint)
}
```

**Step 4: Build**

```bash
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest'
```

**Step 5: Commit**

```bash
git add PeerDrop/Core/ConnectionManager.swift PeerDrop/Transport/DataChannelClient.swift
git commit -m "feat(ios): apply RelayHintsStore to skip P2P on known symmetric NAT networks"
```

---

## Phase 4 — `TailnetPeerStore`

### Task 4.1: `TailnetPeerEntry` struct + Codable round-trip tests

**Files:**
- Create: `PeerDrop/Core/TailnetPeerEntry.swift`
- Create: `PeerDropTests/TailnetPeerEntryTests.swift`

**Step 1: Write failing tests**

```swift
import XCTest
@testable import PeerDrop

final class TailnetPeerEntryTests: XCTestCase {
    func test_encodesDecodesAllFields() throws {
        let e = TailnetPeerEntry(
            id: UUID(), displayName: "Alice's iPad",
            ip: "100.64.1.23", port: 9876,
            lastReachable: Date(timeIntervalSince1970: 1_700_000_000),
            lastChecked: Date(timeIntervalSince1970: 1_700_000_100),
            consecutiveFailures: 0, addedAt: Date(timeIntervalSince1970: 1_600_000_000))
        let data = try JSONEncoder().encode(e)
        let back = try JSONDecoder().decode(TailnetPeerEntry.self, from: data)
        XCTAssertEqual(back.id, e.id)
        XCTAssertEqual(back.ip, "100.64.1.23")
        XCTAssertEqual(back.consecutiveFailures, 0)
    }

    func test_decodeLegacyEntryMissingConsecutiveFailures_defaultsToZero() throws {
        let legacy = #"""
        {"id":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","displayName":"Legacy","ip":"100.64.1.1","port":9876,"addedAt":1700000000}
        """#
        let data = legacy.data(using: .utf8)!
        let e = try JSONDecoder().decode(TailnetPeerEntry.self, from: data)
        XCTAssertEqual(e.consecutiveFailures, 0)
    }
}
```

**Step 2: Run — expect FAIL**

**Step 3: Implement**

```swift
import Foundation

struct TailnetPeerEntry: Codable, Identifiable, Hashable {
    let id: UUID
    var displayName: String
    var ip: String
    var port: UInt16
    var lastReachable: Date?
    var lastChecked: Date?
    var consecutiveFailures: Int
    var addedAt: Date

    init(id: UUID = UUID(), displayName: String, ip: String, port: UInt16 = 9876,
         lastReachable: Date? = nil, lastChecked: Date? = nil,
         consecutiveFailures: Int = 0, addedAt: Date = Date()) {
        self.id = id; self.displayName = displayName; self.ip = ip; self.port = port
        self.lastReachable = lastReachable; self.lastChecked = lastChecked
        self.consecutiveFailures = consecutiveFailures; self.addedAt = addedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        ip = try c.decode(String.self, forKey: .ip)
        port = try c.decode(UInt16.self, forKey: .port)
        lastReachable = try c.decodeIfPresent(Date.self, forKey: .lastReachable)
        lastChecked = try c.decodeIfPresent(Date.self, forKey: .lastChecked)
        consecutiveFailures = try c.decodeIfPresent(Int.self, forKey: .consecutiveFailures) ?? 0
        addedAt = try c.decode(Date.self, forKey: .addedAt)
    }
}
```

**Step 4: Run — expect PASS**

**Step 5: Commit**

```bash
git add PeerDrop/Core/TailnetPeerEntry.swift PeerDropTests/TailnetPeerEntryTests.swift project.yml PeerDrop.xcodeproj
git commit -m "feat(ios): TailnetPeerEntry with legacy-compatible Codable"
```

---

### Task 4.2: `TailnetPeerStore` class (no probing yet)

**Files:**
- Create: `PeerDrop/Core/TailnetPeerStore.swift`
- Create: `PeerDropTests/TailnetPeerStoreTests.swift`

**Step 1: Write failing tests**

```swift
@MainActor
final class TailnetPeerStoreTests: XCTestCase {
    override func setUp() async throws {
        UserDefaults.standard.removeObject(forKey: "peerDropTailnetPeers")
    }

    func test_addPersistsEntry() {
        let store = TailnetPeerStore()
        store.add(displayName: "Alice", ip: "100.64.1.1")
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.displayName, "Alice")

        let reloaded = TailnetPeerStore()
        XCTAssertEqual(reloaded.entries.count, 1)
    }

    func test_removeDeletesEntry() {
        let store = TailnetPeerStore()
        store.add(displayName: "A", ip: "100.64.1.1")
        let id = store.entries.first!.id
        store.remove(id: id)
        XCTAssertTrue(store.entries.isEmpty)
    }
}
```

**Step 2: Run — expect FAIL**

**Step 3: Implement**

```swift
import Foundation
import Combine

@MainActor
final class TailnetPeerStore: ObservableObject {
    @Published private(set) var entries: [TailnetPeerEntry] = []

    private let key = "peerDropTailnetPeers"

    init() { load() }

    func add(displayName: String, ip: String, port: UInt16 = 9876) {
        let entry = TailnetPeerEntry(displayName: displayName, ip: ip, port: port)
        entries.append(entry); persist()
    }

    func remove(id: UUID) { entries.removeAll { $0.id == id }; persist() }
    func rename(id: UUID, to newName: String) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].displayName = newName; persist()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([TailnetPeerEntry].self, from: data) else { return }
        entries = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
```

**Step 4: Run + commit**

```bash
xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/TailnetPeerStoreTests
git add PeerDrop/Core/TailnetPeerStore.swift PeerDropTests/TailnetPeerStoreTests.swift project.yml PeerDrop.xcodeproj
git commit -m "feat(ios): TailnetPeerStore with CRUD + UserDefaults persistence"
```

---

### Task 4.3: `probeAll()` with NWConnection + loopback test

**Files:**
- Modify: `PeerDrop/Core/TailnetPeerStore.swift` (add `probeAll()`)
- Modify: `PeerDropTests/TailnetPeerStoreTests.swift` (add loopback integration test)

**Step 1: Write loopback test**

Listen on 127.0.0.1:<random-port>, add entry, assert probe succeeds.

```swift
func test_probeReachableLoopback() async throws {
    let listener = try NWListener(using: .tcp, on: .any)
    let group = DispatchGroup(); group.enter()
    var boundPort: NWEndpoint.Port = 0
    listener.stateUpdateHandler = { state in
        if case .ready = state, let port = listener.port { boundPort = port; group.leave() }
    }
    listener.newConnectionHandler = { $0.start(queue: .global()) }
    listener.start(queue: .global())
    group.wait()

    let store = TailnetPeerStore()
    store.add(displayName: "Loopback", ip: "127.0.0.1", port: boundPort.rawValue)
    await store.probeAll()
    XCTAssertNotNil(store.entries.first?.lastReachable)
    XCTAssertEqual(store.entries.first?.consecutiveFailures, 0)
    listener.cancel()
}

func test_probeUnreachableMarksAfterTwoFailures() async {
    let store = TailnetPeerStore()
    store.add(displayName: "Nowhere", ip: "192.0.2.1", port: 9876) // RFC 5737 TEST-NET-1
    await store.probeAll()
    XCTAssertEqual(store.entries.first?.consecutiveFailures, 1)
    XCTAssertTrue(store.isReachable(store.entries.first!.id)) // still "reachable" after 1 miss
    await store.probeAll()
    XCTAssertEqual(store.entries.first?.consecutiveFailures, 2)
    XCTAssertFalse(store.isReachable(store.entries.first!.id)) // unreachable after 2
}
```

**Step 2: Run — expect FAIL**

**Step 3: Implement `probeAll()`**

```swift
import Network

extension TailnetPeerStore {
    func isReachable(_ id: UUID) -> Bool {
        guard let e = entries.first(where: { $0.id == id }) else { return false }
        return e.consecutiveFailures < 2 && e.lastReachable != nil
    }

    func probeAll() async {
        await withTaskGroup(of: (UUID, Bool).self) { group in
            for entry in entries {
                group.addTask { [entry] in
                    let ok = await TailnetPeerStore.probeOne(ip: entry.ip, port: entry.port)
                    return (entry.id, ok)
                }
            }
            for await (id, ok) in group {
                guard let idx = self.entries.firstIndex(where: { $0.id == id }) else { continue }
                self.entries[idx].lastChecked = Date()
                if ok {
                    self.entries[idx].lastReachable = Date()
                    self.entries[idx].consecutiveFailures = 0
                } else {
                    self.entries[idx].consecutiveFailures += 1
                }
            }
            self.persist()
        }
    }

    nonisolated private static func probeOne(ip: String, port: UInt16) async -> Bool {
        await withCheckedContinuation { cont in
            let conn = NWConnection(
                host: NWEndpoint.Host(ip),
                port: NWEndpoint.Port(integerLiteral: port),
                using: .tcp)
            var done = false
            let timeout = DispatchWorkItem {
                guard !done else { return }; done = true
                conn.cancel(); cont.resume(returning: false)
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: if !done { done = true; timeout.cancel(); conn.cancel(); cont.resume(returning: true) }
                case .failed, .cancelled: if !done { done = true; timeout.cancel(); cont.resume(returning: false) }
                default: break
                }
            }
            conn.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5, execute: timeout)
        }
    }
}
```

**Step 4: Run — expect PASS**

```bash
xcodegen generate
xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/TailnetPeerStoreTests
```

**Step 5: Commit**

```bash
git add PeerDrop/Core/TailnetPeerStore.swift PeerDropTests/TailnetPeerStoreTests.swift
git commit -m "feat(ios): TailnetPeerStore.probeAll with 500ms timeout + 2-miss rule"
```

---

### Task 4.4: Periodic probe loop (60 s while foregrounded)

**Files:**
- Modify: `PeerDrop/Core/TailnetPeerStore.swift`
- Modify: `PeerDrop/Core/ConnectionManager.swift` (own the store + trigger on scenePhase)

**Step 1: Add probe loop methods to store**

```swift
private var probeTask: Task<Void, Never>?

func startPeriodicProbe() {
    probeTask?.cancel()
    probeTask = Task { [weak self] in
        while !Task.isCancelled {
            await self?.probeAll()
            try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
        }
    }
}

func stopPeriodicProbe() { probeTask?.cancel(); probeTask = nil }
```

**Step 2: Own it in ConnectionManager**

```swift
let tailnetStore = TailnetPeerStore()
```

**Step 3: Wire in scene phase** (in `PeerDropApp.swift`)

```swift
case .active:
    inboxService.connect()
    connectionManager.tailnetStore.startPeriodicProbe()
case .background:
    // existing...
    connectionManager.tailnetStore.stopPeriodicProbe()
```

**Step 4: Build + commit**

```bash
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest'
git add PeerDrop/Core/TailnetPeerStore.swift PeerDrop/Core/ConnectionManager.swift PeerDrop/App/PeerDropApp.swift
git commit -m "feat(ios): TailnetPeerStore 60s probe loop on scene active"
```

---

### Task 4.5: Integrate tailnet peers into `discoveredPeers`

**Files:**
- Modify: `PeerDrop/Core/ConnectionManager.swift` (wherever `discoveredPeers` is computed)

**Step 1: Merge tailnet reachable entries into `discoveredPeers`**

Find the existing discovery coordinator output. Add:

```swift
private func refreshDiscoveredPeers() {
    var peers = existingDiscoveryPeers
    for entry in tailnetStore.entries where tailnetStore.isReachable(entry.id) {
        let peer = DiscoveredPeer(
            id: "tailnet:\(entry.id.uuidString)",
            displayName: entry.displayName,
            endpoint: .manual(host: entry.ip, port: entry.port),
            source: .manual)
        peers.append(peer)
    }
    discoveredPeers = dedupByID(peers)
}
```

Subscribe to `tailnetStore.$entries` to recompute on changes.

**Step 2: Build + commit**

```bash
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest'
git add PeerDrop/Core/ConnectionManager.swift
git commit -m "feat(ios): inject reachable tailnet peers into discoveredPeers"
```

---

### Task 4.6: Auto-reciprocal add on incoming tailnet connection

**Files:**
- Modify: `PeerDrop/Discovery/BonjourDiscovery.swift` (inside `handleIncomingConnection`)
- Modify: `PeerDrop/Core/ConnectionManager.swift` (add helper)

**Step 1: Wire callback**

`ConnectionManager` already receives incoming connections from Bonjour. In the HELLO handler (where `peerIdentity.displayName` is extracted), add:

```swift
if let remoteHost = extractRemoteHost(from: connection.endpoint),
   isTailnetIP(remoteHost) {
    tailnetStore.addIfMissing(displayName: peerIdentity.displayName, ip: remoteHost)
}
```

Add helpers:

```swift
private func extractRemoteHost(from endpoint: NWEndpoint) -> String? {
    switch endpoint {
    case .hostPort(let host, _):
        switch host {
        case .ipv4(let addr): return addr.debugDescription
        case .ipv6(let addr): return addr.debugDescription
        case .name(let s, _): return s
        @unknown default: return nil
        }
    default: return nil
    }
}

private func isTailnetIP(_ ip: String) -> Bool {
    // CGNAT 100.64.0.0/10
    let parts = ip.split(separator: ".").compactMap { UInt8($0) }
    guard parts.count == 4 else { return false }
    return parts[0] == 100 && parts[1] >= 64 && parts[1] <= 127
}
```

Add to `TailnetPeerStore`:

```swift
func addIfMissing(displayName: String, ip: String, port: UInt16 = 9876) {
    if entries.contains(where: { $0.ip == ip }) { return }
    add(displayName: displayName, ip: ip, port: port)
}
```

**Step 2: Build + commit**

```bash
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest'
git add PeerDrop/Core/ConnectionManager.swift PeerDrop/Core/TailnetPeerStore.swift
git commit -m "feat(ios): auto-add incoming tailnet peer on first connect"
```

---

## Phase 5 — `ConnectionContext`

### Task 5.1: `ConnectionContext` with decision tree tests

**Files:**
- Create: `PeerDrop/Core/ConnectionContext.swift`
- Create: `PeerDropTests/ConnectionContextTests.swift`

**Step 1: Write tests covering all 5 branches of decision tree**

```swift
@MainActor
final class ConnectionContextTests: XCTestCase {
    func test_knownDeviceWithPeerDeviceId_returnsInviteKnownDevice() {
        let ctx = ConnectionContext()
        let rec = DeviceRecord(id: "a", displayName: "Alice", sourceType: "relay",
                                lastConnected: Date(), connectionCount: 3,
                                peerDeviceId: "dev-abc")
        ctx.setKnownDeviceSample(rec)
        if case .useInviteKnownDevice = ctx.primaryRecommendation { } else { XCTFail() }
    }

    func test_tailscaleWithPeers_returnsUseTailnet() {
        let ctx = ConnectionContext()
        ctx.setTailscaleState(hasTailscale: true, tailnetPeerCount: 3)
        if case .useTailnet = ctx.primaryRecommendation { } else { XCTFail() }
    }

    func test_tailscaleWithoutPeers_returnsUseRelayCode() {
        let ctx = ConnectionContext()
        ctx.setTailscaleState(hasTailscale: true, tailnetPeerCount: 0)
        if case .useRelayCode = ctx.primaryRecommendation { } else { XCTFail() }
    }

    func test_highFailureRate_returnsConfigureTailscale() {
        let ctx = ConnectionContext()
        ctx.setTailscaleState(hasTailscale: false, tailnetPeerCount: 0)
        ctx.setRecentFailureRate(0.5)
        if case .configureTailscale = ctx.primaryRecommendation { } else { XCTFail() }
    }

    func test_defaultFallback_returnsUseRelayCode() {
        let ctx = ConnectionContext()
        if case .useRelayCode = ctx.primaryRecommendation { } else { XCTFail() }
    }
}
```

**Step 2: Run — expect FAIL**

**Step 3: Implement**

```swift
import Foundation
import Combine

@MainActor
final class ConnectionContext: ObservableObject {
    @Published private(set) var hasTailscale: Bool = false
    @Published private(set) var tailnetPeerCount: Int = 0
    @Published private(set) var lastRelayFailure: Date?
    @Published private(set) var recentFailureRate: Double = 0
    @Published private(set) var knownDeviceSample: DeviceRecord?

    var primaryRecommendation: ConnectionRecommendation {
        if let rec = knownDeviceSample { return .useInviteKnownDevice(rec) }
        if hasTailscale && tailnetPeerCount > 0 { return .useTailnet(suggestedIP: nil) }
        if hasTailscale && tailnetPeerCount == 0 { return .useRelayCode }
        if !hasTailscale && recentFailureRate > 0.3 { return .configureTailscale }
        return .useRelayCode
    }

    // Internal setters for tests + wiring
    func setKnownDeviceSample(_ rec: DeviceRecord?) { knownDeviceSample = rec }
    func setTailscaleState(hasTailscale: Bool, tailnetPeerCount: Int) {
        self.hasTailscale = hasTailscale; self.tailnetPeerCount = tailnetPeerCount
    }
    func setRecentFailureRate(_ rate: Double) { recentFailureRate = rate }
}

enum ConnectionRecommendation: Equatable {
    case useInviteKnownDevice(DeviceRecord)
    case useTailnet(suggestedIP: String?)
    case useRelayCode
    case useQRScan
    case configureTailscale
    case waitForDiscovery
}
```

**Step 4: Run — expect PASS**

```bash
xcodegen generate
xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/ConnectionContextTests
```

**Step 5: Commit**

```bash
git add PeerDrop/Core/ConnectionContext.swift PeerDropTests/ConnectionContextTests.swift project.yml PeerDrop.xcodeproj
git commit -m "feat(ios): ConnectionContext decision tree with 5-branch tests"
```

---

### Task 5.2: Wire ConnectionContext to live signals

**Files:**
- Modify: `PeerDrop/Core/ConnectionContext.swift`
- Modify: `PeerDrop/App/PeerDropApp.swift`

**Step 1: Add `observe(...)` method**

```swift
func observe(deviceStore: DeviceRecordStore, tailnetStore: TailnetPeerStore) {
    // Observe deviceStore for best known device
    deviceStore.$records.sink { [weak self] records in
        let best = records.filter { $0.peerDeviceId != nil }
                          .sorted { $0.lastConnected > $1.lastConnected }
                          .first
        self?.setKnownDeviceSample(best)
    }.store(in: &subs)

    tailnetStore.$entries.sink { [weak self, tailnetStore] _ in
        let reachable = tailnetStore.entries.filter { tailnetStore.isReachable($0.id) }.count
        self?.setTailscaleState(hasTailscale: Self.detectTailscale(), tailnetPeerCount: reachable)
    }.store(in: &subs)
}

private var subs = Set<AnyCancellable>()

private static func detectTailscale() -> Bool {
    // Scan ifaddrs for utun* with 100.x IP
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return false }
    defer { freeifaddrs(ifaddr) }
    for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let i = ptr.pointee
        let name = String(cString: i.ifa_name)
        guard name.hasPrefix("utun"), i.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        getnameinfo(i.ifa_addr, socklen_t(i.ifa_addr.pointee.sa_len),
                    &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        if String(cString: host).hasPrefix("100.") { return true }
    }
    return false
}
```

**Step 2: Inject into App**

In `PeerDropApp.swift`:

```swift
@StateObject private var connectionContext = ConnectionContext()

// In body:
ContentView()
    .environmentObject(connectionManager)
    .environmentObject(inboxService)
    .environmentObject(connectionContext)  // ← NEW
    // ...

// In .onAppear:
connectionContext.observe(
    deviceStore: connectionManager.deviceStore,
    tailnetStore: connectionManager.tailnetStore)
```

**Step 3: Build + commit**

```bash
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest'
git add PeerDrop/Core/ConnectionContext.swift PeerDrop/App/PeerDropApp.swift
git commit -m "feat(ios): ConnectionContext observes deviceStore + tailnetStore"
```

---

## Phase 6 — `GuidanceCard` UI

### Task 6.1: `GuidanceCard` view with 6 visual states

**Files:**
- Create: `PeerDrop/UI/Discovery/GuidanceCard.swift`
- Modify: `PeerDrop/App/Localizable.xcstrings` (add new keys in 5 languages — see Task 6.2)

**Step 1: Implement the view shell**

```swift
import SwiftUI

struct GuidanceCard: View {
    @EnvironmentObject var context: ConnectionContext
    @EnvironmentObject var connectionManager: ConnectionManager
    let trigger: Trigger
    let onMoreOptions: () -> Void
    let onDismiss: (() -> Void)?

    enum Trigger { case emptyState; case failure(reason: String) }

    var body: some View {
        card(for: context.primaryRecommendation)
            .padding(.horizontal, 16).padding(.vertical, 8)
    }

    @ViewBuilder
    private func card(for rec: ConnectionRecommendation) -> some View {
        switch rec {
        case .useInviteKnownDevice(let device):
            primaryCard(icon: "person.crop.circle.fill.badge.checkmark",
                        title: String(localized: "Connect again with \(device.displayName)"),
                        primaryLabel: String(localized: "Invite"),
                        primaryAction: { connectionManager.shouldShowRelayConnect = true }, // open picker
                        subtitle: device.relativeLastConnected)
        case .useTailnet:
            primaryCard(icon: "network.badge.shield.half.filled",
                        title: String(localized: "Found a Tailscale device nearby"),
                        primaryLabel: String(localized: "Connect"),
                        primaryAction: { connectionManager.shouldShowRelayConnect = true },
                        subtitle: String(localized: "Via your tailnet"))
        case .useRelayCode:
            primaryCard(icon: "antenna.radiowaves.left.and.right",
                        title: String(localized: "Create a Relay room"),
                        primaryLabel: String(localized: "Create Room"),
                        primaryAction: { connectionManager.shouldShowRelayConnect = true })
        case .configureTailscale:
            primaryCard(icon: "network.slash",
                        title: String(localized: "Connection keeps failing?"),
                        primaryLabel: String(localized: "Try Tailscale"),
                        primaryAction: openTailscaleAppStore,
                        subtitle: String(localized: "A free VPN that makes cross-network connect feel like same-network"))
        case .useQRScan, .waitForDiscovery:
            EmptyView()
        }
    }

    private func primaryCard(icon: String, title: String, primaryLabel: String,
                             primaryAction: @escaping () -> Void, subtitle: String? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title2).foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold()).foregroundStyle(.white)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.85)) }
            }
            Spacer()
            Button(action: primaryAction) {
                Text(primaryLabel).font(.caption.bold())
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.white, in: Capsule()).foregroundStyle(.blue)
            }
            Button(action: onMoreOptions) {
                Image(systemName: "ellipsis.circle").font(.caption).foregroundStyle(.white.opacity(0.9))
            }
            if let onDismiss {
                Button(action: onDismiss) { Image(systemName: "xmark").font(.caption).foregroundStyle(.white.opacity(0.9)) }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(LinearGradient(colors: [.blue, .indigo], startPoint: .leading, endPoint: .trailing),
                    in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
    }

    private func openTailscaleAppStore() {
        guard let url = URL(string: "https://apps.apple.com/app/tailscale/id1470499037") else { return }
        UIApplication.shared.open(url)
    }
}
```

**Step 2: Build**

```bash
xcodegen generate
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest'
```

**Step 3: Commit (skeleton only, localization next task)**

```bash
git add PeerDrop/UI/Discovery/GuidanceCard.swift project.yml PeerDrop.xcodeproj
git commit -m "feat(ios): GuidanceCard skeleton with 4 visible recommendation states"
```

---

### Task 6.2: Localisation strings for GuidanceCard

**Files:**
- Modify: `PeerDrop/App/Localizable.xcstrings`

**Step 1: Add the following keys in all 5 languages**

- `Connect again with %@`
- `Found a Tailscale device nearby`
- `Via your tailnet`
- `Create a Relay room`
- `Create Room` (reuse if exists)
- `Connection keeps failing?`
- `Try Tailscale`
- `A free VPN that makes cross-network connect feel like same-network`

Edit `Localizable.xcstrings` directly or via Xcode UI. For each key, populate `en`, `zh-Hant`, `zh-Hans`, `ja`, `ko`.

**Step 2: Rebuild to confirm strings resolve**

```bash
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest'
```

**Step 3: Commit**

```bash
git add PeerDrop/App/Localizable.xcstrings
git commit -m "i18n(ios): GuidanceCard strings in 5 languages"
```

---

### Task 6.3: "More options..." sheet

**Files:**
- Create: `PeerDrop/UI/Discovery/ConnectionOptionsSheet.swift`

**Step 1: Implement sheet listing all connection methods**

```swift
struct ConnectionOptionsSheet: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    @Environment(\.dismiss) private var dismiss
    @State private var showManualConnect = false

    var body: some View {
        NavigationStack {
            List {
                Section("Cross-Network") {
                    Button("Create Relay Room") { connectionManager.shouldShowRelayConnect = true; dismiss() }
                    Button("Invite known device") { connectionManager.shouldShowRelayConnect = true; dismiss() }
                    Button("Scan QR code") { /* TODO hook QR scanner */ dismiss() }
                }
                Section("Advanced") {
                    Button("Connect by IP address") { showManualConnect = true }
                    NavigationLink("Manage tailnet peers") { TailnetPeersView() }
                }
            }
            .navigationTitle("Connection Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .sheet(isPresented: $showManualConnect) {
                ManualConnectView().environmentObject(connectionManager)
            }
        }
    }
}
```

(You will create `TailnetPeersView` in Task 7.1; for now add a placeholder so it builds.)

**Step 2: Build + commit**

```bash
xcodegen generate
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest'
git add PeerDrop/UI/Discovery/ConnectionOptionsSheet.swift project.yml PeerDrop.xcodeproj
git commit -m "feat(ios): ConnectionOptionsSheet aggregates all connection methods"
```

---

### Task 6.4: Mount `GuidanceCard` in `NearbyTab` empty state

**Files:**
- Modify: `PeerDrop/UI/Discovery/NearbyTab.swift`

**Step 1: Add state + mount**

```swift
@State private var showOptionsSheet = false
@EnvironmentObject var connectionContext: ConnectionContext

// Inside empty-state Section, after 10s delay:
if peers.isEmpty && elapsedSinceSearch > 10 {
    GuidanceCard(trigger: .emptyState, onMoreOptions: { showOptionsSheet = true }, onDismiss: nil)
}
```

Track `elapsedSinceSearch` via a `TimelineView` or `Timer.publish`.

**Step 2: Present sheet**

```swift
.sheet(isPresented: $showOptionsSheet) {
    ConnectionOptionsSheet().environmentObject(connectionManager)
}
```

**Step 3: Build + commit**

```bash
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest'
git add PeerDrop/UI/Discovery/NearbyTab.swift
git commit -m "feat(ios): mount GuidanceCard in NearbyTab empty state after 10s"
```

---

### Task 6.5: Mount `GuidanceCard.failure` overlay in `ContentView`

**Files:**
- Modify: `PeerDrop/UI/ContentView.swift`

**Step 1: Track failure state + dismissed IDs**

```swift
@State private var failureCardReason: String?
@State private var dismissedFailureIDs: Set<String> = []
@EnvironmentObject var connectionContext: ConnectionContext

// onChange of connectionManager.state:
case .failed(let reason):
    let id = UUID().uuidString
    if !dismissedFailureIDs.contains(id) {
        failureCardReason = reason
    }
```

**Step 2: Overlay**

```swift
if let reason = failureCardReason {
    GuidanceCard(trigger: .failure(reason: reason),
                 onMoreOptions: { /* open sheet */ },
                 onDismiss: { failureCardReason = nil })
        .transition(.move(edge: .top).combined(with: .opacity))
        .padding(.top, 8).zIndex(4)
}
```

**Step 3: Build + commit**

```bash
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest'
git add PeerDrop/UI/ContentView.swift
git commit -m "feat(ios): mount GuidanceCard.failure overlay on relay failure"
```

---

### Task 6.6: Snapshot tests for 6 GuidanceCard states

**Files:**
- Create: `PeerDropTests/GuidanceCardSnapshotTests.swift`

**Step 1: Set up snapshot harness using SwiftUI previews + XCTest image comparison.**

Use the existing `ScreenshotModeProvider` for mock injection. Skip if the repo doesn't already have snapshot infrastructure — simplest alternative: compile-time rendering test (UIHostingController).

```swift
@MainActor
final class GuidanceCardSnapshotTests: XCTestCase {
    func test_useInviteKnownDevice_rendersNonEmpty() {
        let ctx = ConnectionContext()
        let rec = DeviceRecord(id: "a", displayName: "Alice",
                                sourceType: "relay", lastConnected: Date(),
                                connectionCount: 1, peerDeviceId: "d")
        ctx.setKnownDeviceSample(rec)
        let card = GuidanceCard(trigger: .emptyState, onMoreOptions: {}, onDismiss: nil)
            .environmentObject(ctx)
            .environmentObject(ConnectionManager())
        let host = UIHostingController(rootView: card)
        host.view.layoutIfNeeded()
        XCTAssertGreaterThan(host.view.intrinsicContentSize.height, 0)
    }
    // ... equivalent smoke tests for other 3 visible states
}
```

**Step 2: Run + commit**

```bash
xcodegen generate
xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest' -only-testing:PeerDropTests/GuidanceCardSnapshotTests
git add PeerDropTests/GuidanceCardSnapshotTests.swift project.yml PeerDrop.xcodeproj
git commit -m "test(ios): smoke render GuidanceCard in each state"
```

---

## Phase 7 — Tailnet Peer Management UI

### Task 7.1: `TailnetPeersView` list + form

**Files:**
- Create: `PeerDrop/UI/Settings/TailnetPeersView.swift`

**Step 1: Implement list + add/edit/delete**

```swift
struct TailnetPeersView: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    @State private var showAddSheet = false

    var body: some View {
        List {
            Section("Tailnet Peers") {
                ForEach(connectionManager.tailnetStore.entries) { entry in
                    HStack {
                        Image(systemName: "network.badge.shield.half.filled")
                            .foregroundStyle(connectionManager.tailnetStore.isReachable(entry.id) ? .green : .orange)
                        VStack(alignment: .leading) {
                            Text(entry.displayName)
                            Text(entry.ip).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { indexSet in
                    for i in indexSet { connectionManager.tailnetStore.remove(id: connectionManager.tailnetStore.entries[i].id) }
                }
            }
        }
        .navigationTitle("Tailnet Devices")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { showAddSheet = true } label: { Image(systemName: "plus") } } }
        .sheet(isPresented: $showAddSheet) { AddTailnetPeerSheet() }
    }
}

struct AddTailnetPeerSheet: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var ip = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Display Name", text: $name)
                TextField("Tailnet IP (100.x.x.x)", text: $ip)
                    .keyboardType(.decimalPad)
                    .textInputAutocapitalization(.never)
                Section(footer: Text("Port defaults to 9876.")) { EmptyView() }
            }
            .navigationTitle("Add Tailnet Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        connectionManager.tailnetStore.add(displayName: name, ip: ip)
                        dismiss()
                    }
                    .disabled(name.isEmpty || ip.isEmpty)
                }
            }
        }
    }
}
```

**Step 2: Build + commit**

```bash
xcodegen generate
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest'
git add PeerDrop/UI/Settings/TailnetPeersView.swift project.yml PeerDrop.xcodeproj
git commit -m "feat(ios): TailnetPeersView list + add form"
```

---

### Task 7.2: Replace "Tailscale / Manual" section in `DiscoveryView`

**Files:**
- Modify: `PeerDrop/UI/Discovery/DiscoveryView.swift`

**Step 1: Swap section content**

Replace the hard-coded "Connect by IP Address" block with a `NavigationLink` to `TailnetPeersView`:

```swift
Section {
    NavigationLink("Manage Tailnet Peers") {
        TailnetPeersView().environmentObject(connectionManager)
    }
    Button {
        showManualConnect = true
    } label: {
        Label("One-time IP connect", systemImage: "network")
    }
} header: { Text("Tailscale / Manual") }
```

**Step 2: Build + commit**

```bash
xcodebuild build -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest'
git add PeerDrop/UI/Discovery/DiscoveryView.swift
git commit -m "feat(ios): wire TailnetPeersView into DiscoveryView"
```

---

## Phase 8 — Release Prep

### Task 8.1: Update `PrivacyInfo.xcprivacy` to declare analytics telemetry

**Files:**
- Modify: `PeerDrop/App/PrivacyInfo.xcprivacy`

**Step 1: Add analytics-data entry**

Under `NSPrivacyCollectedDataTypes`:

```xml
<dict>
    <key>NSPrivacyCollectedDataType</key>
    <string>NSPrivacyCollectedDataTypeOtherDiagnosticData</string>
    <key>NSPrivacyCollectedDataTypeLinked</key>
    <false/>
    <key>NSPrivacyCollectedDataTypeTracking</key>
    <false/>
    <key>NSPrivacyCollectedDataTypePurposes</key>
    <array>
        <string>NSPrivacyCollectedDataTypePurposeAnalytics</string>
        <string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
    </array>
</dict>
```

**Step 2: Commit**

```bash
git add PeerDrop/App/PrivacyInfo.xcprivacy
git commit -m "privacy(ios): declare analytics telemetry in PrivacyInfo"
```

---

### Task 8.2: Full test suite + manual checklist

**Step 1: Run full suite**

```bash
cd "/Volumes/SATECHI DISK Media/UserFolders/Projects/applications/peer-drop"
xcodebuild test -scheme PeerDrop -destination 'platform=iOS Simulator,name=iPhone 16,OS=latest'
```
Expected: all tests PASS (~740+ after new additions).

**Step 2: Manual test on physical devices**

Run through the checklist from the design doc:

1. Add a tailnet peer → probe succeeds within 60 s → appears in Nearby.
2. Connect to a tailnet peer → the receiver auto-adds the initiator.
3. Disable Wi-Fi (cellular only) → GuidanceCard recommends `.useRelayCode`.
4. Connect Tailscale → GuidanceCard recommends `.useTailnet`.
5. Three relay failures in a row (use Link Conditioner "Very Bad Network") → `.configureTailscale`.
6. Phase-1 → Phase-2 transition: confirm connection completes via relay without reset.

Record any regressions. Do NOT proceed to 8.3 until all six pass.

---

### Task 8.3: Version bump + release

**Files:**
- Modify: `project.yml` (MARKETING_VERSION 3.2.2 → 3.3.0)
- Modify: `fastlane/metadata/*/release_notes.txt` (5 languages)

**Step 1: Bump**

```yaml
MARKETING_VERSION: "3.3.0"
CURRENT_PROJECT_VERSION: "1"
```

**Step 2: Write release notes in 5 languages**

Highlight four things:
- Invite / reconnect suggestions that adapt to your environment
- Tailnet peer management with 60 s probe
- Connection telemetry (opt-out via Settings → Privacy)
- TURN over TLS for corporate networks

**Step 3: Regenerate + final build**

```bash
xcodegen generate
xcodebuild archive -scheme PeerDrop -destination 'generic/platform=iOS' -archivePath /tmp/PeerDrop-3.3.0.xcarchive
```

**Step 4: Commit**

```bash
git add project.yml PeerDrop.xcodeproj fastlane/metadata/
git commit -m "release: bump to v3.3.0 — cross-network experience"
```

**Step 5: Fastlane submit (same flow as v3.2.2)**

```bash
fastlane release
```

After build + upload, if `submit_for_review` fails on `usesNonExemptEncryption`, repeat the API-based submit script from the v3.2.2 playbook (documented in MEMORY).

---

## Rollback Plan

- Remote circuit breaker (`/config/metrics`) can disable client telemetry instantly: `{"sampleRate": 0.0, "enabled": false}`. Update via `wrangler kv key put`.
- Worker `/debug/metric` can be removed in a point-release without affecting iOS (it'll just start logging "drop" debug messages locally).
- iOS GuidanceCard can be disabled by setting `connectionContext.primaryRecommendation` to `.waitForDiscovery` (no UI rendered) — but requires app update.
- TailnetPeerStore is opt-in (users only get entries they added); no migration risk.

---

## Completion Criteria

- All 8 phases committed.
- All unit + integration tests pass in CI.
- Manual real-device checklist passes.
- v3.3.0 `WAITING_FOR_REVIEW` on App Store Connect.
- Worker deployed with new endpoints live for 24 h without 5xx spikes.
