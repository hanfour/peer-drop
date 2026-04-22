# v3.3 Cross-Network Connection Experience — Design

**Status:** Approved design; ready for implementation planning.
**Date:** 2026-04-22
**Scope:** iOS app + Cloudflare Worker.

## Goal

Make cross-network connections (two devices on different Wi-Fi / cellular
networks) as frictionless as same-network connections, by:

- Making failures diagnosable with full-connection telemetry (metadata only).
- Guiding users to the right cross-network method (Relay, Tailscale, known
  device invite) based on their actual environment.
- Reducing the failure rate from symmetric NATs and corporate networks by
  tuning ICE/TURN configuration up-front.
- Giving Tailscale users automatic discovery of peers they have added.

Shipped as a single v3.3 release (not incremental MVPs).

## Background

Post-v3.2.1 real-device testing showed relay connections still fail on some
networks (symmetric NAT, UDP-blocked corporate Wi-Fi). We have no way to
measure which failure modes dominate because only failed connections are
reported today. We also have no automatic Tailscale peer discovery — users
who run Tailscale must type the 100.x.x.x IP by hand each time.

## Non-Goals

- In-app WireGuard / custom VPN. (VPN entitlement + review risk + ops cost.)
- Automated test harness against real Tailscale. (Too flaky; manual tests
  instead.)
- Symmetric-NAT rendezvous server. (ConnectionMetrics will tell us whether
  it is worth building.)
- Remote kill switch via Firebase. (We re-use Worker KV for the same job.)

## Architecture

```
iOS (v3.3)
├─ ConnectionContext       ── decision hub (single source of truth)
│   └─ drives ─▶ GuidanceCard   (shared by empty-state + failure-recovery)
│
├─ TailnetPeerStore        ── user-maintained tailnet IP list + 60 s probe
│   └─ auto-reciprocal:    ── incoming connections from 100.64.0.0/10 are
│                             silently added on the receiver side
│
├─ ConnectionMetrics       ── actor; buffers, flushes to Worker
│   └─ tracks              ── role, outcome, ICE candidate gather + selection
│
└─ ICEConfigurationProvider enhancements
    ├─ TURN over TCP + TLS (turns: port 5349)
    ├─ Candidate pool size = 2
    ├─ Phase-1 / Phase-2 logical deadline (no restartIce)
    └─ Network-fingerprint relay learning
         (fingerprint = subnet + gateway hash; 3 phase-2 successes ⇒ prefer
         relay on that network)

Cloudflare Worker
├─ POST /debug/metric          ── ingest (API_KEY; ≤ 4 KB payload)
├─ GET  /debug/metrics/stats   ── aggregate (ANALYTICS_KEY, new)
└─ GET  /config/metrics        ── remote circuit breaker (no auth)

Storage
└─ METRICS KV namespace        ── key = metric:YYYY-MM-DD:uuid, 14 d TTL
```

## Components

### `ConnectionContext`

Observable object, single source of truth for "what should we tell the
user to do right now?".

```swift
@MainActor
final class ConnectionContext: ObservableObject {
    @Published private(set) var hasTailscale: Bool
    @Published private(set) var tailnetPeerCount: Int
    @Published private(set) var lastRelayFailure: Date?
    @Published private(set) var recentFailureRate: Double   // past hour
    @Published private(set) var knownDeviceCount: Int

    var primaryRecommendation: ConnectionRecommendation { /* see below */ }
}

enum ConnectionRecommendation {
    case useInviteKnownDevice(DeviceRecord)
    case useTailnet(suggestedIP: String?)
    case useRelayCode
    case useQRScan
    case configureTailscale
    case waitForDiscovery
}
```

**Decision tree** (checked top-to-bottom, first hit wins):

1. Known device with `peerDeviceId` exists → `.useInviteKnownDevice`.
2. `hasTailscale && tailnetPeerCount > 0` → `.useTailnet`.
3. `hasTailscale && tailnetPeerCount == 0` → `.useRelayCode`.
4. `!hasTailscale && recentFailureRate > 0.3` → `.configureTailscale`.
5. Default → `.useRelayCode`.

Consumes `ConnectionMetrics.onFailure`, `deviceStore.records` changes, and
`ifaddrs` scans on `scenePhase == .active`.

### `GuidanceCard`

One SwiftUI view, six visual states driven by
`ConnectionContext.primaryRecommendation`. Two triggers:

- `.emptyState` — mounts after 10 s of no Bonjour peers in Nearby tab.
- `.failure(reason, roomCode?)` — pushed from `ContentView` overlay on
  relay failure; session-dismissible.

UX invariants:

- **One card at a time.** Never a grid of options.
- **"More options…" link** at the bottom opens a sheet with every connection
  method, so nothing is unreachable.
- `.failure` cards appear immediately (no 10 s wait) and include a close
  button; once dismissed, suppress for the rest of the session.

### `TailnetPeerStore`

Persistent list of user-added tailnet devices plus a background probe.

```swift
struct TailnetPeerEntry: Codable, Identifiable {
    let id: UUID
    var displayName: String
    var ip: String              // 100.x.x.x typically, but not enforced
    var port: UInt16            // locked to 9876 in v3.3
    var lastReachable: Date?
    var lastChecked: Date?
    var consecutiveFailures: Int
    var addedAt: Date
}
```

Probe loop:

- Runs on `scenePhase == .active`, every 60 s.
- Parallel `NWConnection` TCP-connect to `ip:9876`; 500 ms timeout.
- Marks `reachable` only after `consecutiveFailures == 0`; marks
  `unreachable` after `consecutiveFailures >= 2` (UI stability).

Auto-reciprocal add:

- `BonjourDiscovery.handleIncomingConnection` inspects the remote endpoint.
- If remote IP is in `100.64.0.0/10` and the HELLO carries a `displayName`,
  silently call `tailnetStore.addIfTailnet(…)`.
- Users can delete any entry from Settings.

### `ConnectionMetrics`

```swift
struct ConnectionMetric: Codable {
    let id: String                // random UUID — no device identity
    let timestamp: Date
    let connectionType: ConnectionType
    let role: Role
    let outcome: Outcome          // .success | .failure(reason) | .abandoned
    let durationMs: Int
    let iceStats: ICEStats?
    let platform: String
    let appVersion: String
    let networkType: NetworkType
    let hasTailscale: Bool
    let hasIPv6: Bool
}

struct ICEStats: Codable {
    let candidatesGathered: [CandidateType]      // enum only, no IPs
    let candidatesUsed: CandidateType?
    let srflxGatherOrder: Int?
    let relayGatherOrder: Int?
    let firstConnectedMs: Int?
    let phase1ConnectedMs: Int?
    let phase2ConnectedMs: Int?
    let ipv6CandidateGathered: Bool
    let ipv6Connected: Bool
}
```

Implementation:

```swift
actor ConnectionMetrics {
    static let shared = ConnectionMetrics()
    func begin(type:, role:) -> Token
    func recordICEGather(_ token:, candidate:, gatherMs:)
    func recordConnected(_ token:, used:)
    func recordFailure(_ token:, reason:)
    // Buffer up to 50; flush every 60 s and on background transition.
}
```

Token lifecycle:

- `class Token { deinit { /* record .abandoned if not finalized */ } }`.
- Non-`Sendable`; lives inside the actor; outside code holds a weak
  reference via a helper.

Privacy:

- No IP, no port, no peer name, no room code.
- `Privacy Manifest` updated to declare `NSPrivacyCollectedDataTypeDiagnosticData`
  with purpose `AnalyticsTelemetry`.
- Sample rate defaults to 1.0, overridable by the remote config endpoint.

### `ICEConfigurationProvider` enhancements

- **TURN over TCP / TLS.** Worker `POST /room/:code/ice` adds
  `turn:…:3478?transport=tcp` and `turns:…:5349?transport=tcp` to the
  returned `iceServers`. The TLS variant survives DPI-filtered corporate
  networks (looks like HTTPS).
- **Candidate pool.** `RTCConfiguration.iceCandidatePoolSize = 2`. Warms
  up STUN before `createOffer`.
- **Phase-1 / Phase-2 logical deadlines.**
  - `0–8 s` — accept any `.connected` pair; WebRTC's natural preference
    tends toward host/srflx.
  - `8–20 s` — if still `.checking`, accept relay pairs on arrival (no
    `restartIce`, no configuration reset).
  - `> 20 s` — transition to `.failed`.
  - Implemented by observing `iceConnectionState` and
    `selectedCandidatePairChanged`, not by swapping configuration.
- **Network-fingerprint relay learning.**
  - `fingerprint = SHA256(subnet + gatewayIP).prefix(8)`.
  - `UserDefaults` key `peerDropRelayHints: [String: Int]`.
  - Three phase-2 successes on the same fingerprint ⇒ next connection on
    that network starts with `iceTransportPolicy = .relay` (skip P2P
    gather, saves 5–8 s).
  - Any phase-1 success resets the counter to 0.

## Data Flow

1. App launch: `ConnectionContext.refresh()` → updates `hasTailscale`,
   probes `TailnetPeerStore`. `ConnectionMetrics.fetchRemoteConfig()`.
2. Connection attempt: `ConnectionMetrics.begin(…) → Token`; WebRTC
   creates peer connection; gathered candidates streamed to
   `recordICEGather`.
3. Phase-1 deadline at 8 s: if still `.checking`, wait for relay pair.
4. Connected: `recordConnected(used:)`; metric flushed in next batch.
5. Failed: `recordFailure(reason:)`; `ConnectionContext.lastRelayFailure`
   updated; `GuidanceCard(.failure)` may mount.
6. Worker stats: `GET /debug/metrics/stats?range=24h` with
   `ANALYTICS_KEY` for operator dashboards.

## Error Handling

| Failure | Handling |
|---|---|
| Tailnet probe timeout (500 ms) | Bump `consecutiveFailures`; keep last `reachable` marker until ≥ 2 consecutive misses. |
| Remote config fetch fails | Use last cached `UserDefaults` value; first-run default is `{sampleRate: 1.0, enabled: true}`. |
| Worker `/debug/metric` non-200 | Drop the metric. Do not queue, do not retry. Sampling loss is acceptable at 100 % rate. |
| ICE Phase-2 timeout (20 s) | Transition to `.failed`; trigger `GuidanceCard(.failure)`. |
| `Token` deinits without finalize | Recorded as `.abandoned` (separate from `.failure`). |
| Tailscale detection fails | `hasTailscale = false`; normal path. |
| Payload > 4 KB at Worker | Worker returns 413; iOS drops on rejection. |

## Testing

| Level | Coverage |
|---|---|
| Unit | `ConnectionContext.primaryRecommendation` all branches; `TailnetPeerEntry` Codable round-trip (with legacy); `ConnectionMetrics` buffer/flush; `networkFingerprint` stability. |
| Integration (loopback) | `TailnetPeerStore.probeAll()` with `127.0.0.1` reachable + unreachable ports; `ConnectionMetrics` with mock URLSession, payload schema check. |
| UI snapshot | Six `GuidanceCard` states × dark/light × 5 languages. |
| Worker | `POST /debug/metric` accepts valid payload; 5 KB payload → 413; `GET /debug/metrics/stats?range=24h` aggregates correctly; `GET /config/metrics` returns current JSON. |
| Network fingerprint stability | (A) Same subnet + gateway, SSID rename — fingerprint stable (no reprobe). (B) Wi-Fi → 5 G — subnet changes — fingerprint changes — fresh learning counter. |
| Manual real-device | See checklist below. |

Manual real-device checklist (blocks App Store submission):

1. Add a tailnet peer → probe succeeds within 60 s → appears in Nearby.
2. Connect to a tailnet peer → the receiver auto-adds the initiator.
3. Disable Wi-Fi (cellular only) → `GuidanceCard` recommends
   `.useRelayCode`.
4. Connect Tailscale → `GuidanceCard` recommends `.useTailnet`.
5. Three relay failures in a row → `GuidanceCard` recommends
   `.configureTailscale`. Reproduce under Network Link Conditioner "Very
   Bad Network" profile.
6. Phase-1 → Phase-2 transition: restrict direct path, confirm connection
   completes via relay without connection reset.

## Rollout

- v3.3 single App Store release; all modules ship together.
- Privacy Manifest updated in the same submission.
- Worker deploy precedes iOS release to make sure `/debug/metric` and
  `/config/metrics` are already live when the new build reaches users.
- Remote config `config:metrics` seeded to `{sampleRate: 1.0, enabled: true}`
  before deploy; can be adjusted without a new app release.

## Open Questions

- ANALYTICS_KEY distribution: tuck it into `wrangler secret` and share
  only with the developer; never embed in the iOS binary.
- Privacy Manifest category for `NetworkInterfacesData` needs Apple's
  current guidance (verify before submission).
