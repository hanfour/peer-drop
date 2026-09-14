# MainActor hot-path offload — design (2026-08-11)

Design-only. No code changes land from this doc; it exists to be reviewed and
signed off before the refactor starts (per the arch-review finding that this is
the single largest structural debt and must be designed first).

## Problem

Every connection and persistence class is `@MainActor`, so all per-byte work
runs on the one main thread:

- **Transport** — `ConnectionManager`, `PeerConnection`, `FileTransfer`,
  `FileTransferSession`, `VoiceCallManager`, `MailboxManager` are `@MainActor`.
  Each 64 KB file chunk's JSON+base64 encode/decode, ChaChaPoly encrypt/decrypt,
  SHA-256, and disk read/write happen on main. `HashVerifier.sha256(fileAt:)`
  hashes the **whole file synchronously** before the first byte is sent.
- **Proof-of-work** — `ProofOfWork` (difficulty 16, up to ~10M SHA-256) runs
  **synchronously on MainActor** at connection setup.
- **Persistence** — `ChatManager` is `@MainActor`; every write is "decrypt whole
  file → decode → append → encrypt → rewrite", and `updateStatus` scans+rewrites
  every conversation file, all on main.

Consequence: 2–3 concurrent transfers, or one large-file hash, freeze the UI and
cap throughput at one core. This is the real scalability ceiling — not the
signalling worker.

## Goal / non-goals

- **Goal:** move CPU- and IO-bound work (crypto, hashing, base64/JSON coding,
  file IO) off the main thread, while keeping SwiftUI-observable state
  (`@Published`) on the main actor. No behavior change; measurable main-thread
  relief.
- **Non-goals:** changing the wire protocol, the on-disk formats, or the public
  API surface. Not a rewrite — an incremental, test-guarded migration.

## Design principle: split "state" from "work"

Today each type mixes three concerns on `@MainActor`:

1. **UI/observable state** — `@Published` arrays, connection status. *Must* stay
   on the main actor (SwiftUI requirement).
2. **Coordination** — deciding what to send, sequencing. Cheap; fine on main.
3. **Heavy work** — crypto, hashing, coding, file IO. The problem.

The refactor pulls (3) out of the main actor into a **background execution
context**, leaving (1) and (2) where they are. The pattern per call site:

```
// on MainActor (coordination) → hop to background (work) → hop back (state)
let chunk = try await CryptoIO.shared.sealChunk(bytes, key: key)   // background
try await connection.send(chunk)                                   // background IO
self.progress = fraction                                           // back on main
```

Two mechanisms, used where each fits:

- **A `CryptoIO` actor** (or a set of `nonisolated` async functions backed by a
  dedicated `DispatchQueue`/`TaskExecutor`) that owns no shared mutable state and
  runs seal/open/hash/encode. Pure functions of their inputs → trivially
  `Sendable`, no data races. This covers the transport hot path and PoW.
- **`nonisolated` async methods** on `ChatManager` for the file-crypto portion of
  persistence, with the actor boundary re-crossed only to publish results. The
  `@Published` state and the pending/debounce bookkeeping stay main-actor.

Inputs crossing the boundary must be `Sendable` (`Data`, `SymmetricKey`,
value structs already are; audit any class references).

## Phased migration (each phase independently shippable + test-guarded)

**Phase 0 — measurement harness.** Add a signpost/os_signpost around the four
hot paths and a debug counter of main-thread time per transfer. Establishes the
before/after number so "it's faster" is evidence, not vibes. (No behavior
change.)

**Phase 1 — PoW off-main (smallest, highest-ratio win).** Make `ProofOfWork`
solve on a background task; `await` the result at the call sites
(`ConnectionManager` ~1431/1526/466). Pure compute, no shared state → lowest
risk. **Acceptance:** connection setup no longer blocks the main thread for the
PoW duration (signpost shows PoW off-main); existing PoW tests still green.

**Phase 2 — File-transfer chunk pipeline.** Move `FileTransferSession`'s
per-chunk seal/open + `HashVerifier` hashing to `CryptoIO`; make the whole-file
pre-send hash async and incremental. Keep progress `@Published` updates on main.
**Acceptance:** a large-file send/receive keeps the main thread responsive
(signpost), throughput improves on a 2-transfer test; the transfer round-trip
tests still pass. (Naturally sequences ahead of the separate `bufferedAmount`
back-pressure fix, `#15`.)

**Phase 3 — Persistence file-crypto.** Extract the decrypt→decode and
encode→encrypt halves of `persistMessages` / `loadMessages` / `updateStatus`
into `nonisolated` async helpers; keep pending/debounce state and `@Published`
arrays on main. **Acceptance:** opening a large conversation and `updateStatus`
no longer block main (signpost); the existing `ChatManager*Tests` (now 15+
cases) all pass unchanged — they already assert the observable behavior, so they
guard the refactor.

**Phase 4 — Voice/mailbox review.** Audit `VoiceCallManager` /`MailboxManager`
for remaining on-main crypto; move as needed. Lower priority (smaller payloads).

## Risks & mitigations

- **Data races** from moving work off the isolated actor → only move *pure*
  functions of `Sendable` inputs; never share the mutable `@Published` state
  across the boundary. Compile with strict concurrency (`-strict-concurrency=
  complete`) on the touched targets to let the compiler prove it.
- **Ordering** — chunks must stay ordered. Keep the send loop's sequencing on the
  coordinating actor; parallelize only the per-chunk *work*, then send in order.
- **Test coverage** — the existing behavior tests are the safety net; do not
  change them during the refactor (green through every phase = no regression).
- **Scope creep** — resist merging the `#15` back-pressure / factory-singleton
  fixes into this; they compose but are separate commits.

## Sequencing vs other work

Phase 1 can start immediately. Phases 2–3 are independent of the deploy-gated
worker changes and of the strict-policy rollout. This refactor gates any future
throughput feature (bigger files, groups at scale), so it's worth doing before
`#15`'s connection-robustness work, which assumes a non-blocked main thread.

## Open question for sign-off

`CryptoIO` as an **actor** (simplest, serial executor) vs **nonisolated async
functions on a concurrent `TaskExecutor`** (more parallelism across chunks, more
care needed). Recommendation: start with the actor (correctness first, Phase
1–2), measure, and only introduce a concurrent executor in Phase 2 if the
signpost shows the serial executor is itself a bottleneck.
