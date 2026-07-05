# Remaining-work implementation roadmap (2026-07-05)

The 2026-07-03→05 session closed every code-shaped item (PRs #120–#132).
Four items remain, each blocked on something outside the repo — an offline
key, a release cut, real hardware, or a test toolchain. This doc turns each
into an actionable plan: phases, what's buildable-now vs external, and the
acceptance criteria that mean "done".

## Critical path — one convergence point

```
                    ┌─────────────────────────────────────────┐
   NEXT iOS RELEASE │ carries: production crypto-policy pubkey │
   (the pivot)      │          + #127 metrics uploader (in main)│
                    └──────────────┬──────────────────────────┘
                                   │ soak 2–4 weeks
        ┌──────────────────────────┼───────────────────────────┐
        ▼                          ▼                            ▼
  [1] activate strict      real soak data lands        (iCloud verify can
      crypto policy         → gate reads real numbers    ride the same build)
```

The **next iOS release is the pivot**: it must bundle the production
crypto-policy public key AND is what makes real soak telemetry flow. Cut it
deliberately. The other three items are independent of it.

Priority order for execution: **[4] webterm E2E** (fully buildable now, no
external dep) → **[3] iCloud verify prep** (buildable diagnostic now, 2-device
test later) → **[2] macOS ship** (operator, unblocks a whole platform) →
**[1] strict policy** (gated on the release + soak).

---

## [1] Activate strict crypto policy

**Goal:** flip C1 to `spkExpirationBehavior: reject` in production, on a
trustworthy trust root, gated on real soak data.

**Status:** repo scaffolding DONE (PR #129) — `cloudflare-worker/strict-policy.json`,
the hardened `tools/activate-strict-policy.sh`, and the full runbook at
`docs/plans/2026-07-05-strict-policy-activation.md`. Nothing more to build.

**Remaining (operator + release), in order:**
1. **Offline keygen** — generate the production Ed25519 keypair on an
   air-gapped machine; store the private key in 1Password (only copy).
   Command in the strict-policy plan §A.
2. **Swap the trust root** — replace the dev public key in `project.yml`'s
   `CryptoPolicyPublicKeys` (the ⚠️-marked line) with the production public
   key; re-sign `bundled-default-policy.signed.json` with the production
   key; `npm run prebuild`; `xcodegen generate`. Ship in the next release.
3. **Soak** — after the build propagates ~2–4 weeks, real metrics accumulate.
4. **Gate + activate** — run `activate-strict-policy.sh --prod-key <offline>
   --analytics-key <ANALYTICS_KEY>` (dry run first). The script refuses the
   dev key, an un-swapped key, an under-populated/`truncated` soak, and any
   non-zero soak-gate counter. Add `--deploy` when the gate passes.

**Acceptance:** `curl …/v2/config/crypto-policy | jq .policy.spkExpirationBehavior`
returns `"reject"`; soak-gate counters stayed ≈0 through the window.

**Rollback:** `wrangler secret delete CRYPTO_POLICY_JSON` → bundled default
(warn) within the 1-hour device cache window.

---

## [2] Ship macOS v6.0 to the Mac App Store

**Goal:** PeerDrop for Mac live on the Mac App Store.

**Status:** code-complete; `Ringtone.caf` (the last asset) landed in #120.
Detailed task breakdown: `docs/superpowers/plans/2026-06-06-m4-mas-submission-prep.md`.
The fastlane lanes (`release_mac` / `check_status_mac` / `submit_mac_only` /
`release_now_mac`), 5-lang macOS metadata, reviewer notes, snapshots, Privacy
Manifest, AppIcon.icns, and the Playwright IAP-attach script (`Scripts/mac-iap-attach/`)
already exist.

**Phase 0 — buildable pre-flight now (de-risks the operator steps):**
- `fastlane check_status_mac` to confirm ASC auth + read current state.
- Verify `fastlane/metadata/macos/` has all 5 langs with **v6.0.0** release
  notes (the #121 staleness guard covers `release_mac` too — confirm it
  passes for 6.0.0).
- Dry-run the Mac archive locally (`xcodebuild archive` unsigned) to catch
  any bundle-validation gap before the signed path.

**Remaining (operator — Apple account operations), in order:**
1. **Developer portal** — App ID `com.hanfour.peerdrop.mac`: enable Push,
   Microphone, App Sandbox, iCloud, keychain-access-groups (now that #130
   added the entitlement). Then `fastlane run get_provisioning_profile
   force:true` to regenerate the Mac profile (the two-step capability ship
   from `feedback-capability-add-twostep-ship`).
2. **ASC** — add the macOS platform to the PeerDrop app record.
3. **Ship binaries** — `fastlane release_mac submit:false` (upload) → it lands
   in PREPARE_FOR_SUBMISSION.
4. **IAP re-attach** — run `Scripts/mac-iap-attach/` (Playwright) to bind the
   3 tip-jar IAPs, same flow as v5.3.2.
5. **Submit** — `fastlane submit_mac_only` → WAITING_FOR_REVIEW.
6. **Post-approval** — MAS-install smoke check on the store binary; tag
   `v6.0.0` once READY_FOR_SALE.

**Acceptance:** Mac app READY_FOR_SALE; a store-installed build launches,
finds a nearby peer, and completes a paired voice call (the 7-row hardware
matrix in the release runbook).

**Watch:** the Apple-Silicon-Mac availability of the iPhone app was turned
OFF 2026-07-05 (post key-rotation) — the native Mac app is the Mac story now.

---

## [3] Verify iCloud pet sync on real hardware

**Goal:** prove end-to-end pet propagation across two devices on one iCloud
account (the merge logic is unit-tested; real KVS/container propagation never
was).

**Surface under test:** `PetCloudSync` (NSUbiquitousKeyValueStore metadata +
a `Documents/PetData/pet.json` in the ubiquity container) and
`PetSyncCoordinator.push()` / `resolvedLaunchPet()`, wired at launch in both
`PeerDropApp` and `PeerDropMacApp`. Conflict resolution = `PetConflictResolver`
(same-id → newest write; different-id → more-invested pet).

**Phase 0 — buildable now (make the invisible observable):**
- **A diagnostic surface** (DEBUG-only): a hidden Settings row / log line that
  dumps, on demand: iCloud account availability (`FileManager.ubiquityIdentityToken
  != nil`), the ubiquity container URL, the last `push()` timestamp, the local
  vs cloud `pet.updatedAt`, and the KVS `pet_id/pet_level/pet_exp` values. This
  turns "did it sync?" from guesswork into a readout. ~1 small PR, TDD the
  formatter with injected values.
- **A real-container integration test** guarded to run only when a ubiquity
  token is present (skips in CI/Simulator): round-trips a pet through
  `syncFullState` → `loadAndMigrateFromCloud` against the real container, and
  asserts the KVS change-notification fires. Documents the manual path in code.

**External phase — the 2-device protocol (needs 2 devices, same Apple ID):**
1. **Fresh-hatch propagation** — hatch a pet on device A, background it (push
   fires), foreground device B, confirm the same species/mood/stats appear
   within the KVS latency window (seconds–minutes). Use the diagnostic surface
   to confirm timestamps, not vibes.
2. **Edit propagation** — feed/evolve on A → observe on B.
3. **Conflict** — edit both offline, bring both online → confirm
   `PetConflictResolver` picks the more-invested pet, no data loss.
4. **Cold-start restore** — delete+reinstall on B → the pet restores from
   iCloud (and the "egg hatched" flag now fires, per #130).

**Acceptance:** all four scenarios pass with observed timestamps; the
`PetCloudSync.swift:71` restore-mirror TODO is closed (the flag-mirror shipped
in #130 — confirm on-device).

**Risk:** iCloud KVS is best-effort and latency is unbounded; document the
observed propagation time so support has a baseline, don't assert a hard SLA.

---

## [4] webterm browser end-to-end tests

**Goal:** real-browser E2E for the self-hosted web terminal, closing the gap
the Swift in-process tests (`WebTermTests`, HummingbirdTesting `TestClient`)
can't reach: the actual xterm.js frontend, WebSocket terminal I/O, auth flows,
and the mobile hotkey bar.

**This one is fully buildable now — the only blocker was the toolchain.**

**Phase 0 — stand up the toolchain (buildable now):**
1. `webterm-e2e/` dir with `package.json` + `@playwright/test` + a
   `playwright.config.ts` (chromium + one mobile viewport for the hotkey-bar
   tests).
2. A test fixture that boots the webterm server on a random localhost port
   with a known password + a temp tmux/session dir, and tears it down. Reuse
   the launch path from `PeerDropKit/Sources/webterm/main.swift`.
3. A first smoke test: navigate → password login → type `echo hello` → assert
   `hello` renders in the xterm buffer (read via `page.locator('.xterm-rows')`
   or the xterm accessibility tree).

**Test scenarios (build out from the smoke test):**
- **Auth:** password happy-path + wrong-password 401 + the login rate-limiter
  (5 fails → 429); CSRF double-submit rejection; the Cf-Access JWT path with a
  stubbed/fixture JWKS.
- **Terminal I/O:** command echo, ANSI rendering, a long-running process,
  Ctrl-C interrupt via the key bar.
- **Session persistence:** open a session, run a command, disconnect the WS,
  reconnect → scrollback/session survives (tmux-backed).
- **Mobile:** the on-screen hotkey bar (Esc/Tab/Ctrl/arrows/^C) sends the
  right sequences; Ctrl sticky-state clears on a key-bar tap.

**CI integration:** a new `webterm-e2e.yml` workflow (or a job in the existing
worker/CI file) that installs Playwright browsers and runs the suite on
push/PR touching `PeerDropKit/Sources/webterm/**`. Gate at chromium first;
add webkit if the frontend needs Safari coverage.

**Acceptance:** the smoke test + auth + terminal-I/O + reconnect scenarios
pass in CI on chromium; the pending-browser-E2E follow-up in the webterm memory
is closed.

**Effort:** Phase 0 ~half a day; full scenario suite ~1–2 days. No external
dependency — this can start immediately.

---

## Sequencing summary

| # | Item | Buildable now | External blocker | Unblocks |
|---|------|---------------|------------------|----------|
| 4 | webterm E2E | **all of it** | none | test confidence for the web terminal |
| 3 | iCloud verify | diagnostic + guarded test | 2 devices | closes a v5.5.0 risk |
| 2 | macOS ship | pre-flight checks | Apple portal/ASC | a whole platform |
| 1 | strict policy | done (#129) | offline key + release + soak | the v5.4 crypto rollout |

**Recommended next action:** start [4] webterm E2E (zero external dep, closes a
real coverage gap) and [3]'s diagnostic surface in parallel — both are pure
code and can ship this session. The macOS ship and strict-policy activation
wait on operator/release actions that are fully documented above.
