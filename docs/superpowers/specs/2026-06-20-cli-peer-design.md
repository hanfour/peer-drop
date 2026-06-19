# PeerDrop CLI Peer — Design Spec

**Date:** 2026-06-20
**Status:** Approved (brainstorming) → ready for implementation plan
**Author:** Claude + hanfour

---

## 1. Summary

A headless macOS command-line executable, `peerdrop-cli`, that wraps a child
process (a shell by default, or an AI agent such as `claude`) inside a
pseudo-terminal (PTY) and bridges that process's terminal I/O to a PeerDrop
conversation. From the phone's point of view, **each running `peerdrop-cli`
instance is one peer — one conversation partner** — discovered, paired, and
chatted-with through the *exact same* connection stack the app already uses to
talk to other devices.

Running several instances (different agents, different working directories)
gives the phone several simultaneous conversation partners.

This unifies two requested use cases into one mechanism:

- **Wrap an AI agent** (`peerdrop-cli -- claude`) → you chat with the agent
  from your phone.
- **Wrap a shell** (`peerdrop-cli -- /bin/zsh`) → you get a remote command
  line, from which you can launch agents or run anything ("remotely open an
  agent, then drive the process").

## 2. Goals / Non-Goals

### Goals
- Reuse PeerDrop's existing connection, pairing, encryption, and protocol
  stack with **zero protocol divergence** from the app.
- One CLI instance = one peer = one conversation; multiple instances = multiple
  simultaneous conversations.
- Work both on local Wi-Fi and remotely (relay), so the phone can drive the
  computer when away from it.
- Phone-side MVP requires **no new UI** — reuse the existing chat interface.
- Secure by reusing PeerDrop's SAS pairing + trusted-contact trust model.

### Non-Goals (this spec)
- Non-macOS targets (Linux/Windows). macOS only.
- A terminal-faithful (xterm) phone experience — deferred to Phase 2.
- Runtime process management / multiple processes per CLI instance — Phase 2.
- Packaging / distribution story (Homebrew, notarized binary) — tracked
  separately, after the executable builds and runs.

## 3. Key Decisions (locked during brainstorming)

| Decision | Choice |
|---|---|
| What the CLI is | Wraps a process via PTY; default `$SHELL`, or any `-- <cmd>` |
| Topology | 1 phone ↔ N CLIs; each CLI = 1 process session = 1 conversation |
| Target platform | **macOS only** — reuse PeerDropKit wholesale |
| Implementation route | **A** — new SPM executable target reusing `ConnectionManager` headless; Phase 0 spike de-risks it |
| Security posture | Paired-only (SAS + trusted-contact); **auto-accept** after one-time enrollment; full shell allowed. Security boundary = the paired phone |
| Phone experience | **Chat-style default** (reuse existing chat UI); terminal-faithful view is Phase 2 (both ultimately wanted) |
| Output segmentation | **idle-flush** heuristic for MVP; prompt-boundary detection is a later refinement |
| Connection path | Same selection as app: local Wi-Fi (Bonjour/TCP) preferred, else relay **live WebRTC data channel**; store-and-forward mailbox only as offline fallback |

## 4. Architecture

### 4.1 Reuse vs. new

The overwhelming majority of the stack is **reused unchanged**; the genuinely
new logic is two small pieces (`ProcessBridge` + the headless entry point).

| Layer | Source | Role |
|---|---|---|
| Connection / pairing / multi-peer orchestration | **Reuse** `PeerDropCore.ConnectionManager` + transports | Same as app, driven headless |
| Encryption (X3DH / Double Ratchet / SAS) | **Reuse** `PeerDropSecurity` | Untouched |
| Wire protocol / message framing | **Reuse** `PeerDropProtocol` (`textMessage`, etc.) | Untouched |
| Local Wi-Fi (Bonjour/TCP) + relay (WebRTC) | **Reuse** `PeerDropTransport` | All three paths usable on macOS |
| `peerdrop-cli` executable target | **New** (SPM executable) | `main` loop + bootstrap |
| `HeadlessPlatform` | **New** (thin) | Device name, no haptics, identity store path |
| `ProcessBridge` | **New** (core new logic) | PTY spawn; PTY output → chat messages; chat messages → PTY input |
| `AgentSession` | **New** (thin) | Binds one `ProcessBridge` ↔ connected peer(s); lifecycle |

### 4.2 Component responsibilities

- **`peerdrop-cli` (executable target).** Parses args (`--name`, `--restart`,
  `-- <cmd>`), constructs `HeadlessPlatform`, boots `ConnectionManager` on an
  async main-actor run loop, advertises identity, wires `AgentSession`, handles
  signals. What it does: turns a process + a PeerDrop identity into a
  discoverable, chattable peer.

- **`HeadlessPlatform`.** Implements the platform-dependency surface
  `ConnectionManager` needs without a GUI app lifecycle: device/display name,
  no-op haptics, and the per-instance identity/trusted-contact storage location.
  Depends on: macOS Keychain or a file under a per-instance directory.

- **`ProcessBridge`.** Owns the child process and its PTY master fd. Two pumps:
  (1) PTY master → segment into chat messages (ANSI-strip + idle-flush) →
  emit; (2) inbound chat text → write line + `\n` to PTY master. Manages echo
  suppression, output backpressure, and a bounded scrollback buffer. What it
  does: makes a terminal stream look like a chat conversation, and vice-versa.
  Testable in isolation with fake commands (`echo`, `cat`).

- **`AgentSession`.** Connects `ProcessBridge` to the set of trusted peers
  attached to this instance: routes their inbound `textMessage`s into the
  bridge, broadcasts the bridge's outbound messages to all attached peers,
  replays scrollback on (re)attach, and reports process lifecycle events
  ("session ended (exit N)").

### 4.3 Phase 0 spike (de-risk route A)

Before building anything else, write the minimal program that:
1. Boots `ConnectionManager` headless in a CLI async main loop (no SwiftUI).
2. Advertises identity (Bonjour) and accepts an incoming connection.
3. Exchanges one plaintext message end-to-end with the iOS app.

If `ConnectionManager`'s `@MainActor` + Combine coupling prevents a clean
headless boot, fall back to route B (a thin hand-wired orchestrator over the
portable subset). The spike result gates the rest of the plan.

## 5. Data Flow

### 5.1 One-time enrollment (the meaning of "auto-accept")

"Auto-accept" does **not** mean "no pairing" — it means pairing happens **once**
and is not re-confirmed per session.

```
Operator (at the computer) starts peerdrop-cli. It prints its fingerprint:
   peerdrop-cli ready · fingerprint A1B2 C3D4 E5F6 · waiting for pairing…
Phone discovers the peer → initiates → both derive a 6-digit SAS →
operator confirms the phone and terminal show the same SAS → approves.
CLI stores the phone's identity key in its trusted-contact file (persisted).
```

Thereafter, that phone reconnecting → CLI matches the trusted contact →
**hands over a session with no further prompt**. This reuses PeerDrop's
existing SAS + trusted-contact mechanism; no new trust primitive is introduced.

Unpaired identities attempting to connect are rejected — only the enrollment
flow can establish trust.

### 5.2 Steady-state bridge

```
Phone sends textMessage ──(existing E2E channel)──▶ CLI decrypts one line of text
        ▲                                                  │ write to PTY master + "\n"
        │                                                  ▼   (= submit one prompt/command)
   chat bubble ◀──(existing E2E channel)── segment PTY output ◀── process stdout/stderr (PTY)
```

### 5.3 Chat-mode output segmentation (`ProcessBridge` heuristic)

A PTY is a continuous byte stream; chat needs discrete messages. Rules:
- **Strip control codes:** remove ANSI color/cursor sequences (chat mode only;
  terminal mode in Phase 2 preserves them raw).
- **idle-flush:** accumulate output; when output goes quiet for ~300–400 ms
  (or the buffer exceeds a size cap), flush the accumulated text as one message.
  `claude` finishing a reply emits one bubble; `ls` completing emits one bubble.
- **Echo off:** disable PTY echo in chat mode so the sender does not see its own
  command echoed back.
- **Backpressure:** throttle when the process floods output (DataChannelTransport
  already chunks at 60 KB); the scrollback buffer is bounded.

Prompt-boundary detection (segment on shell prompt) is a more precise but more
fragile alternative, deferred as a later refinement.

### 5.4 Multi-device attach

One CLI instance hosts **one** process session. If the owner's multiple devices
connect, they share the same terminal (output broadcast to all, input merged) —
like screen sharing. MVP uses this simplest model; typically only one phone is
attached.

### 5.5 Role advertisement

The CLI advertises a `role: agent` capability flag (in the hello/identity
exchange and the Bonjour TXT record) plus a descriptive name
(`Mac-mini · claude`). MVP: the phone chats through the existing UI; the flag is
only used later (Phase 2) to enable a "terminal view" toggle. **Phone MVP =
zero new UI.**

## 6. Identity & Discovery

- Each CLI instance has its **own** identity (key pair + peer ID), named via
  `--name`. The identity/trusted-contact store is per-instance (keyed by
  `--name`/working directory) so multiple instances appear as distinct peers.
- **Local Wi-Fi:** advertise Bonjour `_peerdrop._tcp`, TXT carrying `pid` +
  `role=agent` → phone discovers it on the same network.
- **Remote:** register prekey bundle / device record with the signaling worker →
  when the phone is off-network it connects via the relay's **live WebRTC data
  channel** (interactive streaming uses the live channel, not store-and-forward
  mailbox; mailbox is only an offline fallback).
- Connection-path selection mirrors the app: same network → local; else relay.

## 7. Error Handling & Lifecycle

| Situation | Behavior |
|---|---|
| Wrapped process exits | Notify attached peers "session ended (exit N)"; `--restart` auto-restarts, else CLI exits |
| Phone drops (leaves Wi-Fi / switches network) | **Process kept alive**; phone reconnects via relay and re-attaches the same session; scrollback replayed. Remote control must survive network blips |
| Multiple peers attach | Shared session (§5.4) |
| `SIGINT` / `SIGTERM` | Clean shutdown: kill child, deregister, close channels |
| Output flood | Throttle + bounded scrollback (§5.3) |
| Unpaired identity connects | Rejected (only enrollment establishes trust) |

## 8. Testing

- **Unit:** `ProcessBridge` — PTY spawn, ANSI stripping, idle-flush
  segmentation, verified with fake commands (`echo`/`cat`) asserting
  line-correspondence.
- **Integration:** loopback transport (reuse the `NoOpTransport` / loopback
  injection seam from `RelayTrustGateIntegrationTests`) sends one `textMessage`,
  asserts it bridges to process stdin and output returns as a chat message;
  include the two truth-table cases unpaired-rejected and paired-auto-accepted.
- **End-to-end (manual):** iOS simulator ↔ `peerdrop-cli -- claude` on the Mac;
  pair once, then chat for real (runtime observation per the `verify` skill).

## 9. Phasing

- **Phase 0 — spike:** confirm `ConnectionManager` boots headless, advertises,
  and receives one plaintext message. Gates everything else.
- **Phase 1 — MVP:** `peerdrop-cli -- <cmd>`, PTY bridge, idle-flush chat
  segmentation, one-time pairing + auto-accept, local + relay, process/reconnect
  lifecycle, multi-peer share. Phone uses the **existing chat UI**; CLI peers
  appear in the peer list with descriptive names. Deliverable = a buildable SPM
  executable (distribution/packaging deferred).
- **Phase 2:** terminal-faithful mode (raw PTY passthrough + phone xterm view +
  `role`-flag toggle), runtime process switching/management, precise
  prompt-boundary segmentation, scrollback-replay polish.

## 10. Open Questions / Risks

- **Headless `ConnectionManager` boot (primary risk):** resolved by the Phase 0
  spike; route B is the fallback.
- **PTY on macOS:** use Darwin `openpty()` / `forkpty()`; child gets the
  controlling terminal. Confirm clean teardown (no zombie/orphan processes).
- **WebRTC binary headless:** `RTCPeerConnection` should not require an
  `NSApplication` run loop, but verify in the spike if a relay connection is
  exercised early.
- **idle-flush tuning:** the 300–400 ms threshold is a starting point; expose it
  as a flag and tune against real `claude` / shell sessions.
