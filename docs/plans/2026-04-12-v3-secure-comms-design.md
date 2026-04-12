# PeerDrop v3.0 Design — Truly Secure P2P Communication

> **Date:** 2026-04-12
> **Status:** Approved
> **Competitor Context:** XChat (X/Twitter standalone messaging app, launching 2026-04-17)
> **Brand Position:** "The only truly private communication app — keys never leave your device."

---

## 1. Competitive Analysis: XChat

### 1.1 XChat Overview

XChat is X's standalone encrypted messaging app, launching April 17, 2026 on iOS.
Positions itself as a WhatsApp/Telegram/iMessage competitor with "Bitcoin-style encryption."

**Features:**
- End-to-end encrypted messaging (claimed)
- Voice & video calls (no phone number required)
- File sharing (all formats)
- Group chat (up to 481 members)
- Disappearing messages (5 min), screenshot blocking
- No ads, privacy-first branding
- X Money payment integration (planned)

### 1.2 XChat Security Weaknesses

| Issue | Detail |
|-------|--------|
| Private keys stored on X servers | Not on device — protected only by 4-digit PIN |
| No forward secrecy | Compromised key decrypts ALL historical messages |
| No published protocol | No whitepaper, no independent audit |
| No MITM protection | X's own help page admits this |
| Legal compliance | Can hand over messages via legal process |
| E2E only for paid users | Free users may not get encryption |

Sources:
- [PBX Science — XChat Security Analysis](https://pbxscience.com/xchat-security-analysis-safe-as-bitcoin-style-peer-to-peer-encryption/)
- [Virtru — E2EE Gold Standard](https://www.virtru.com/blog/xchats-launch-and-why-end-to-end-encryption-remains-the-gold-standard)
- [Atomic Mail — Privacy Claims vs Reality](https://atomicmail.io/blog/xchat-by-elon-musk-overview-privacy-claims-vs-reality)

### 1.3 PeerDrop vs XChat Differentiation

| Dimension | PeerDrop | XChat |
|-----------|----------|-------|
| Connection | Local network + BLE + WebRTC | Cloud servers |
| Account required | No | X account required |
| Offline capability | Fully offline | None |
| Privacy model | True P2P, zero-knowledge relay | Centralized, keys on server |
| Key storage | Device-only (Secure Enclave) | X servers (4-digit PIN) |
| Forward secrecy | Yes (Signal Protocol) | No |
| Encryption audit | Signal Protocol (open, audited) | Unpublished, unaudited |
| Unique feature | Pet evolution system | X ecosystem integration |
| User base | Independent small app | Backed by X's hundreds of millions |

---

## 2. Strategy: Hybrid Architecture

**Core idea:** Local-first with truly secure remote relay.

- **Local communication:** Maintain existing architecture, enhance with CryptoKit + Curve25519 E2E
- **Remote communication:** Signal Protocol via zero-knowledge Cloudflare Worker relay
- **Key management:** All private keys device-only; public keys exchanged via local pairing or QR code
- **Pet system:** Pet becomes the UI embodiment of trust and security states
- **Local enhancements:** Batch transfer, folder sharing developed in parallel

### Core Principles

1. **Keys never leave the device** — Secure Enclave generation and storage, no iCloud backup
2. **Zero-knowledge relay** — Cloudflare Worker forwards ciphertext only, no storage, no metadata logging
3. **Local-first** — Same network auto-routes to local direct connection (faster, lower power)
4. **Trust through face-to-face** — QR code / local pairing for public key exchange, no server trust required

---

## 3. Encryption Layer Design

### 3.1 Key Hierarchy

```
Generated on first device launch:

Identity Key Pair (long-term identity)
  Algorithm: Curve25519
  Generated: Secure Enclave
  Storage: iOS Keychain (kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
  Backup: NEVER backed up to iCloud
  Purpose: Long-term device identity, one per device

Signed Pre-Key (rotated every 7 days)
  Signed with identity private key (prevents forgery)
  Purpose: X3DH key agreement for remote connections

One-Time Pre-Keys (batch of 100, replenished when depleted)
  Each used exactly once then destroyed
  Purpose: Unique key per new conversation

Session Keys (per-message via Double Ratchet)
  New key derived for every message
  Old keys automatically destroyed
  Purpose: Forward Secrecy + Future Secrecy (Break-in Recovery)
```

### 3.2 Local Communication Encryption (Same Network)

```
Alice (local)                              Bob (local)
    |                                          |
    |-- Bonjour broadcast (with pubkey fingerprint) -->|
    |<-- Bonjour response (with pubkey fingerprint) ---|
    |                                          |
    |   [First pairing]                        |
    |   QR Code scan or                        |
    |   NearbyInteraction proximity confirm    |
    |   -> Exchange full public keys           |
    |   -> Compare fingerprints                |
    |   -> Both confirm                        |
    |                                          |
    |   [Subsequent connections]               |
    |   Bonjour discovery auto-matches         |
    |   known pubkey fingerprints              |
    |   -> Match = auto-connect                |
    |                                          |
    |-- ECDH key agreement (Curve25519) ------>|
    |<-- Derive shared secret (HKDF-SHA256) ---|
    |                                          |
    |== AES-256-GCM encrypted channel ==========|
    |   (all messages, files, calls encrypted) |
```

**Why local doesn't need full Signal Protocol:**
- Local is true direct connection, no intermediary server to eavesdrop
- ECDH + AES-256-GCM is military-grade encryption
- Reduces latency and computation overhead

### 3.3 Remote Communication Encryption (Different Networks)

```
Full Signal Protocol flow:

Alice                  Zero-Knowledge Relay      Bob
  |                         |                      |
  |-- Request Bob's prekey bundle -->|              |
  |<-- Return Bob's:         |                      |
  |    - Identity Key (pub)  |                      |
  |    - Signed Pre-Key      |                      |
  |    - One-Time Pre-Key    |                      |
  |                          |                      |
  |  [X3DH Key Agreement]                          |
  |  DH1 = Alice Identity x Bob Signed             |
  |  DH2 = Alice Ephemeral x Bob Identity          |
  |  DH3 = Alice Ephemeral x Bob Signed            |
  |  DH4 = Alice Ephemeral x Bob OneTime           |
  |  SharedSecret = KDF(DH1 || DH2 || DH3 || DH4) |
  |                          |                      |
  |== Encrypted msg (ciphertext) ==>|== Forward ==>|
  |                          |                      |
  |  Relay sees:             |   Bob receives:      |
  |  - encrypted blob        |   - X3DH restore key |
  |  - cannot read content   |   - decrypt message  |
  |  - cannot identify who   |                      |
  |    sent to whom          |                      |
  |  (anonymous mailbox ID)  |                      |
  |                          |                      |
  |  [Double Ratchet starts]                        |
  |  Every message:                                 |
  |   - Symmetric ratchet -> new Message Key        |
  |   - Every reply -> DH ratchet -> new Chain Key  |
  |   - Old keys automatically destroyed            |
  |                                                 |
  |  Result: even if key N is compromised,          |
  |  messages 1..(N-1) remain encrypted             |
  |  (Forward Secrecy)                              |
  |  AND messages (N+1).. also remain encrypted     |
  |  (Future Secrecy / Break-in Recovery)           |
```

---

## 4. Zero-Knowledge Relay Server

### 4.1 Architecture

Extends existing Cloudflare Worker (`peerdrop-signal.hanfourhuang.workers.dev`).

```
Components:

1. Pre-Key Server
   - Stores: device public keys + Signed Pre-Key + One-Time Pre-Keys
   - Storage: Cloudflare KV (encrypted public key data)
   - ONLY stores public keys, NEVER touches private keys

2. Message Relay
   - Pure forward: receive ciphertext -> forward to target mailbox
   - No storage: discard immediately after forwarding
   - Offline mailbox: temporarily store ciphertext when recipient offline
     - Max 7 days retention
     - Content = encrypted ciphertext (server cannot read)
     - Deleted once retrieved
   - No logging: no logs, no metadata, no IP records

3. Anonymous Mailbox
   - Each device has a random Mailbox ID
   - Mailbox ID has no association to device identity
   - Periodic Mailbox ID rotation to prevent tracking

4. WebRTC Signaling (existing, preserved)
   - Remote calls / large file transfer via WebRTC
```

### 4.2 Server Knowledge Boundary

```
Server KNOWS (unavoidable):        Server DOES NOT KNOW (zero-knowledge):
- Mailbox ID exists                - Who owns which Mailbox ID
- Ciphertext delivered to mailbox  - Message content
- Ciphertext size                  - Who sent to whom
- Public key bundles (already      - Message type (text/file/call)
  public information)              - User IP (CF does not log + future Tor)
                                   - Any historical messages
```

### 4.3 API Design

```
POST /v2/keys/register        - Upload device public key bundle, bind to Mailbox ID
GET  /v2/keys/{mailboxId}     - Retrieve target's prekey bundle for X3DH
POST /v2/messages/{mailboxId} - Deliver encrypted message to target mailbox
GET  /v2/messages             - Pull pending messages from own mailbox (server deletes after pull)
POST /v2/mailbox/rotate       - Rotate Mailbox ID (migrate pending messages)
DELETE /v2/keys               - Revoke all keys (device lost)

--- Existing API preserved ---
POST /signal                  - WebRTC signaling (existing)
GET  /signal/:roomId          - WebRTC signaling (existing)
```

### 4.4 Anti-Abuse (Without Sacrificing Privacy)

```
1. Proof-of-Work (Hashcash-style)
   - Each message requires a PoW token
   - Normal user: 50-100ms computation, no UX impact
   - Spammer: massive computational cost for bulk sending

2. Cloudflare Rate Limiting
   - Per IP: 60 req/min
   - Per Mailbox: 200 msg/day receive limit
   - Exceeding = auto-discard

3. Client-side blocking
   - Unknown public key -> prompt "unverified contact"
   - One-tap block -> locally reject all messages from that key
   - Block list stored device-only
```

### 4.5 Legal Process Compliance

Architecture is designed so we **technically cannot provide** user data:

```
In response to legal process, we can provide:
- Mailbox ID exists (random string, cannot be linked to identity)
- Public key bundles (already public information)
- Unretrieved offline ciphertext (cannot be decrypted)
- NO IP logs
- NO user identity data
- NO social graph
- NO message content

Precedent: Signal has successfully responded to federal subpoenas
with "this is all we have" and courts accepted it.
```

### 4.6 Cloudflare Technology Stack

```
Compute: Cloudflare Workers (existing)
Storage: Cloudflare KV
  - Public key bundles: persistent
  - Offline messages: TTL 7 days auto-expire
  - Mailbox mappings: persistent
Advantages:
  - Global edge nodes, low latency
  - Free tier sufficient for initial usage
  - Workers do not log by default
  - Existing infrastructure in place
```

---

## 5. Trust Model & Contact Management

### 5.1 Trust Levels

| Level | Icon (SF Symbol) | How Established | Security |
|-------|------------------|-----------------|----------|
| Verified | `lock.shield` | Face-to-face QR scan or local network pairing | Highest — public key confirmed in person, MITM impossible |
| Linked | `link.circle` | Remote invite link (not verified in person) | High — E2E encrypted but key not confirmed face-to-face. Shows "recommend verifying next time you meet" |
| Unknown | `exclamationmark.triangle` | Received connection request from unknown key | Untrusted — message shows warning, user must actively accept |

### 5.2 Pairing Flow: Face-to-Face (Highest Trust)

```
Alice and Bob are in the same location:

Alice                                    Bob
  |                                       |
  | (1) Open PeerDrop -> "Add Contact"    |
  |     -> "Face-to-Face Pairing"         |
  |     -> Screen shows QR Code           |
  |        (contains: Alice public key    |
  |         + random pairing code         |
  |         + timestamp)                  |
  |                                       |
  |                    Bob scans Alice's QR |
  |                    Bob's app returns:   |
  |                    - Bob's public key   |
  |                    - Pairing confirm sig |
  |                                       |
  | (2) Both screens show simultaneously: |
  |     +----------------------------+    |
  |     | Safety Number: 38291 04827 |    |
  |     |                            |    |
  |     | [cat sprite] <-> [dog sprite] | |
  |     | Alice's pet greets         |    |
  |     | Bob's pet!                 |    |
  |     |                            |    |
  |     | Confirm numbers match      |    |
  |     | [Confirm] [Cancel]         |    |
  |     +----------------------------+    |
  |                                       |
  | (3) Both confirm -> Trust: lock.shield |
  |     -> Public key saved to contacts   |
  |     -> Pet earns "New Friend" badge   |
  |     -> Can immediately chat/transfer  |
```

### 5.3 Pairing Flow: Remote Invite Link

```
Alice wants to invite remote Carol:

Alice                                         Carol
  |                                             |
  | (1) "Add Contact" -> "Remote Invite"        |
  |     App generates invite link:              |
  |     peerdrop://invite?                      |
  |       id=<random invite ID>&                |
  |       pk=<Alice pubkey fingerprint>&        |
  |       exp=<24h expiry>                      |
  |                                             |
  | (2) Send link via any channel               |
  |     (iMessage, LINE, Email...)              |
  |     Link itself contains no secrets         |
  |     (only pubkey fingerprint, not full key) |
  |                                             |
  |                          Carol taps link --->|
  |                          App opens, shows:   |
  |                          "Alice invites you" |
  |                          [Accept] [Decline]  |
  |                                             |
  | (3) Carol accepts -> via relay:             |
  |     - Carol uploads prekey bundle           |
  |     - Alice retrieves Carol's bundle        |
  |     - X3DH key agreement completes          |
  |     - Encrypted channel established         |
  |                                             |
  | (4) Trust level: link.circle (not verified) |
  |     UI shows:                               |
  |     +-------------------------------+       |
  |     | Carol (link.circle Linked)    |       |
  |     | exclamationmark.triangle      |       |
  |     | Not yet verified in person    |       |
  |     | Tap to verify next time ->    |       |
  |     +-------------------------------+       |
  |                                             |
  | (5) Later in person -> QR verification      |
  |     -> Upgrade to lock.shield Verified      |
```

### 5.4 Key Change Detection (MITM Prevention)

```
If Bob's key changes (new phone, reinstall, or attack):

+-------------------------------------------+
| exclamationmark.shield Security Warning    |
|                                           |
| Bob's encryption key has changed.         |
| This could be because:                    |
| - Bob got a new phone                     |
| - Bob reinstalled PeerDrop                |
| - Someone is trying to impersonate Bob    |
|                                           |
| Previous trust: lock.shield Verified      |
| Current trust: Needs re-verification      |
|                                           |
| [cat sprite looks confused/alert]         |
| "Your pet senses something is off..."     |
|                                           |
| [Block] [Accept New Key] [Verify Later]   |
+-------------------------------------------+

- Unlike WhatsApp: silently accepting new keys (insecure)
- Unlike Signal: small text notification (easy to miss)
- PeerDrop: full-screen warning + pet reaction + clear action options
```

### 5.5 Contact Data Structure (Local Storage)

```swift
struct TrustedContact: Codable {
    let id: UUID
    let displayName: String
    let identityPublicKey: Data          // Curve25519 public key
    let keyFingerprint: String           // Public key fingerprint (display)
    let trustLevel: TrustLevel           // verified / linked / unknown
    let firstConnected: Date             // First connection time
    let lastVerified: Date?              // Last face-to-face verification
    let mailboxId: String?               // Remote mailbox ID
    let userId: String?                  // Future: account user ID
    let petSnapshot: PetSnapshot?        // Peer's pet snapshot (display)
    var isBlocked: Bool

    // Encrypted in Keychain, not backed up to iCloud
    // Uses ChatDataEncryptor (existing architecture)
}

enum TrustLevel: String, Codable {
    case verified   // lock.shield — face-to-face verified
    case linked     // link.circle — remote connected, unverified
    case unknown    // exclamationmark.triangle — unknown source
}
```

---

## 6. Account System & Cross-Device (Future-Ready)

### 6.1 Core Principle

```
Account ≠ Key
Account = a label grouping multiple devices

WRONG (XChat's approach):
  Upload private key to server -> any device can log in -> security collapse

CORRECT (Signal's approach, we adopt):
  Each device has its own key pair -> account is just a "device group" label
```

### 6.2 Multi-Device Architecture

```
User Account (cloud):
  user_id: "usr_abc123"
  auth: email / Apple ID (login only)
  display_name: "Han"
  subscription: free / pro
  devices: [
    {
      device_id: "dev_iphone",
      device_name: "Han's iPhone",
      identity_public_key: <public key>,
      signed_pre_key: <signed prekey>,
      mailbox_id: "mbx_xxx",
      last_seen: "2026-04-12"
    },
    {
      device_id: "dev_ipad",
      device_name: "Han's iPad",
      identity_public_key: <different public key>,
      signed_pre_key: <different signed prekey>,
      mailbox_id: "mbx_yyy",
      last_seen: "2026-04-12"
    }
  ]

  Server ONLY stores public keys. Private keys stay on each device.

  Sending a message to Han:
  -> Encrypt one copy for iPhone's public key
  -> Encrypt one copy for iPad's public key
  -> Deliver to each device's Mailbox separately
  (Each device decrypts independently)
```

### 6.3 New Device Binding Flow

```
Han bought a new iPad:

iPhone (logged in)                       iPad (new device)
    |                                       |
    | (1) iPad logs into account            |
    |     Server: "new device requesting"   |
    |                                       |
    | (2) iPhone receives push:             |
    |  +------------------------------+    |
    |  | exclamationmark.shield        |    |
    |  | New device wants to join      |    |
    |  | Device: "Han's iPad"          |    |
    |  |                               |    |
    |  | [pet sprite looks alert]      |    |
    |  |                               |    |
    |  | [Scan QR to verify] [Decline] |    |
    |  +------------------------------+    |
    |                                       |
    | (3) Face-to-face QR scan              |
    |     -> iPhone confirms iPad's pubkey  |
    |     -> iPad confirms iPhone's pubkey  |
    |     -> Cross-sign                     |
    |                                       |
    | (4) iPhone sends contact list         |
    |     (pubkeys + trust + display names) |
    |     encrypted with iPad's public key  |
    |     NOTE: sends contact metadata,     |
    |     NOT private keys                  |
    |     NOTE: chat history NOT synced     |
    |     (each device independent)         |
    |                                       |
    | (5) Done:                             |
    |     - iPad has its own key pair       |
    |     - iPad knows all contacts' pubkeys|
    |     - Contacts' next messages encrypt |
    |       for both devices                |
    |     - Pet earns "New Home" badge      |
```

### 6.4 Subscription Tiers

| Feature | Free | Pro |
|---------|------|-----|
| Devices | 1 | Up to 5 |
| Local transfer | Unlimited | Unlimited |
| Remote messages | 50/day | Unlimited |
| Remote file transfer | 100MB/day | 10GB/day |
| Offline mailbox retention | 24 hours | 7 days |
| Contacts | 10 | Unlimited |
| Pet features | Basic raising | Rare genes, costumes, multiple pets |
| Group chat | Up to 5 | Up to 50 |
| Account system | Device-only | Account + cross-device |
| Price | $0 | $2.99/mo or $29.99/yr |

**Design principles:**
- Local features always free (this is core differentiation)
- Paid unlocks: remote + cross-device + advanced pet
- Server costs supported by Pro users
- Free users get full security guarantees (no encryption downgrade)

### 6.5 Architecture Pre-Planning

```
Reserve NOW in v3.0:                    Implement LATER in v3.1:
- TrustedContact.userId field           - Account registration/login UI
- Mailbox ID supports multi-device      - Multi-device key sync flow
- API design reserves device_id param   - StoreKit 2 subscriptions
- Data structures reserve subscription  - Usage counting & limits
                                        - Account management settings
                                        - Device management UI
                                        - Multi-device message delivery
```

---

## 7. Local Feature Enhancements

### 7.1 Batch Transfer & Folder Sharing

```
TransferQueueManager:

Multi-select:
  - Photos: PHPickerViewController (multi-select)
  - Files: UIDocumentPickerViewController (multi-select + folder)
  - Drag & Drop: support from other apps (iPad)
  - Share Extension: share multiple files from any app

Folder transfer:
  - Recursively scan folder structure
  - Preserve directory structure, send file by file (not zipped -> individual progress)
  - Send manifest.json first (file list + structure)
  - Receiver preview: "Receiving 3 folders, 47 files, 1.2GB" -> [Accept] [Decline]
  - Auto-restore directory structure to Files.app

Queue UI:
  +------------------------------------+
  | Sending to Bob (lock.shield)       |
  |                                    |
  | folder  Project Files/    3/12     |
  | [========----------]  45%  2.1MB/s |
  |                                    |
  | doc  IMG_0291.heic    checkmark    |
  | doc  IMG_0292.heic    [========] 78%|
  | doc  report.pdf       clock        |
  |                                    |
  | [Pause All] [Cancel]               |
  +------------------------------------+

Smart scheduling:
  - Small files first (quick visible progress)
  - Same-type files parallel (max 3 concurrent channels)
  - Large files auto-chunked (256KB chunks)
  - Disconnect auto-pause -> resume from breakpoint on reconnect
```

### 7.2 Enhanced Resumable Transfer

```
Chunk-Based Transfer Protocol:

File chunking:
  - 256KB per chunk (local) / 64KB per chunk (remote)
  - Each chunk independently encrypted (AES-256-GCM)
  - Each chunk has SHA-256 checksum
  - Each chunk independently acknowledged (ACK)

Disconnect recovery:
  - Sender records: which chunks delivered (bitmap)
  - Receiver records: which chunks received and verified
  - On reconnect: exchange bitmaps -> only retransmit missing chunks
  - Cross-session: transfer_id persisted (app closed and reopened can resume)

Integrity verification:
  - Per-chunk: SHA-256 (real-time)
  - Whole file: SHA-256 (after completion)
  - Checksum failure -> auto-retransmit that chunk only
```

### 7.3 Smart Channel Selection

```
Same Wi-Fi:
  - Primary: NWConnection (TCP direct)
  - Speed: up to 100+ MB/s
  - Use for: large files, batch transfer

Bluetooth:
  - Fallback: BLE + L2CAP
  - Speed: ~2 MB/s
  - Use for: no Wi-Fi, small files, messages

Remote:
  - Messages: Cloudflare Worker relay
  - Large files: WebRTC DataChannel (P2P direct)
    -> ICE traversal success = direct (fast)
    -> ICE traversal failure = TURN relay (slower but works)
  - Auto-select best path

Auto-switching:
  - Mid-transfer Wi-Fi drops -> auto-switch to BLE and resume
  - Peer leaves local -> auto-switch to remote and resume
  - Peer returns to local -> auto-switch back to direct (faster)
```

---

## 8. Pet System Integration

### 8.1 Pet as Security UX Embodiment

| Security Event | Pet Reaction |
|----------------|-------------|
| Face-to-face pairing success | Two pets interact happily, exchange gifts |
| Remote connection established | Pet curiously looks into the distance |
| Key change warning | Pet alert, fur stands up |
| Encrypted transfer in progress | Pet carries a package, running (progress visualization) |
| File delivered | Pet jumps happily + XP earned |
| Long time unused | Pet bored, napping |
| Block unknown contact | Pet fiercely protects owner |
| New device joins account | Pet moving-house animation |

### 8.2 Pet Social Deepening

```
Local connection:
  - Both pets interact on same screen (real-time sync)
  - Can feed each other's pets
  - Pets develop friendship level
    (frequent interaction = special animations)
  - Unlock "Good Friend" / "Best Friend" badges

Remote connection:
  - Pet snapshot exchange (lightweight, no performance impact)
  - Send "pet gifts" (special food/decorations)
  - Social diary records remote interactions

Pro exclusive:
  - Rare gene unlock (special colors, patterns)
  - Pet costume system (hats, scarves, accessories)
  - Multiple pets (up to 3)
  - Pet breeding (two Pro users' pets can have babies,
    inheriting both parents' genes)
```

### 8.3 Pet as Security Education Tool

```
Pet Security Dashboard (replaces traditional security settings):

+------------------------------------------+
| [cat sprite] Mochi's Security Report     |
|                                          |
| shield.lefthalf.filled Protection: Excellent |
| [============]                           |
|                                          |
| checkmark.circle Keys safely stored on device |
| checkmark.circle 3 verified friends      |
| exclamationmark.triangle 1 friend not yet verified |
| checkmark.circle All conversations encrypted |
|                                          |
| Mochi says:                              |
| "I feel safe! But Carol hasn't been      |
|  verified in person yet. Remember to     |
|  verify next time you see her~"          |
|                                          |
+------------------------------------------+

Effect: Users don't need to understand "forward secrecy."
       Pet happy = you're secure.
       Pet uneasy = security issue needs attention.
```

---

## 9. Icon Design System (SF Symbols, Outline Style)

All UI icons use SF Symbols in outline style, consistent with existing project design language.

### Security / Trust
| Purpose | SF Symbol |
|---------|-----------|
| Verified | `lock.shield` |
| Linked | `link.circle` |
| Unknown | `exclamationmark.triangle` |
| Key warning | `exclamationmark.shield` |
| Encrypting | `lock` |

### Transfer
| Purpose | SF Symbol |
|---------|-----------|
| Send | `arrow.up.circle` |
| Receive | `arrow.down.circle` |
| Complete | `checkmark.circle` |
| Waiting | `clock` |
| Paused | `pause.circle` |
| Folder | `folder` |
| File | `doc` |
| Photo | `photo` |

### Contacts / Social
| Purpose | SF Symbol |
|---------|-----------|
| Add contact | `person.badge.plus` |
| Group | `person.3` |
| QR Code | `qrcode` |
| Block | `hand.raised` |

### Connection
| Purpose | SF Symbol |
|---------|-----------|
| Wi-Fi | `wifi` |
| Bluetooth | `antenna.radiowaves.left.and.right` |
| Remote | `globe` |
| Offline | `wifi.slash` |

### Pet
| Purpose | SF Symbol |
|---------|-----------|
| Pet | pixel sprite (existing system) |
| Achievement | `star.circle` |
| Food | `leaf.circle` |

### Account / Settings
| Purpose | SF Symbol |
|---------|-----------|
| Account | `person.circle` |
| Device | `iphone` |
| Pro | `crown` |
| Settings | `gearshape` |

---

## 10. Development Phases

### Phase 1 — Security Foundation (v3.0-alpha)
- CryptoKit key management (Secure Enclave)
- Local communication E2E encryption (ECDH + AES-256-GCM)
- Contact trust model (verified / linked / unknown)
- QR Code face-to-face pairing
- Key change detection and warning
- Unit test coverage for encryption layer

### Phase 2 — Remote Communication (v3.0-beta)
- Signal Protocol integration (libsignal-ios)
- Zero-knowledge Cloudflare Worker v2 API
- Pre-key server
- Anonymous mailbox system
- Remote invite link
- Proof-of-Work anti-abuse
- End-to-end tests (local <-> remote switching)

### Phase 3 — Local Enhancements (v3.0-rc)
- Batch transfer + folder sharing
- Chunk-based resumable transfer
- Smart channel switching
- Transfer queue UI
- Performance testing (large files, many files)

### Phase 4 — Pet Integration (v3.0)
- Pet security reaction animations
- Pet security dashboard
- Pet visits (local real-time interaction)
- Pet gift system
- Security education pet dialogue

### Phase 5 — Account & Monetization (v3.1)
- Account system (Apple ID / Email)
- Multi-device binding flow
- StoreKit 2 subscriptions
- Free / Pro feature gating
- Pro pet features (rare genes, costumes, breeding)

### Phase 6 — Cross-Platform (v4.0, future)
- Android version (Kotlin, shared encryption protocol)
- Or Web version (WebCrypto API)
- Cross-platform interoperability testing
