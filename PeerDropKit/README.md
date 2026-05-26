# PeerDropKit

Local Swift Package containing the cross-platform core of the PeerDrop app.
Consumed by both the iOS app target (`PeerDropApp-iOS`, eventual `PeerDropApp-macOS`)
and the `PeerDropWidget` extension.

## Modules

| Module | Purpose | External dependencies |
|---|---|---|
| `PeerDropCore` | App-level orchestration: ConnectionManager, ChatManager, UserProfile, InboxService, Platform/ registry | none |
| `PeerDropTransport` | Network/transport layer: Bonjour, PeerConnection, RelaySession, WebRTC, voice transport pieces | WebRTC |
| `PeerDropSecurity` | Cryptography: PeerIdentity, ChatDataEncryptor, Double Ratchet, SAS, relay crypto | CryptoKit (Apple) |
| `PeerDropProtocol` | Wire format + envelope + version negotiation | none |
| `PeerDropPet` | Pet system: PetGenome, SpeciesCatalog, PetRendererV3, sprite atlas decoding | ZIPFoundation |

## Dependency graph

```
PeerDropPet ────┐
PeerDropSecurity ─┐
PeerDropProtocol ─┼──> PeerDropCore ──> (app targets)
PeerDropTransport ┘
```

Strict single-direction. Enforced via `swift build` (cycles would not compile)
and via the macOS-platform target declaration (UI-framework imports would
fail on macOS even if iOS happens to accept them).

## Status

| Milestone | Status | Description |
|---|---|---|
| M1c | ✅ shipped | Package scaffold + empty placeholder modules |
| M1d | pending | Migrate ~90 source files from `PeerDrop/` into modules |
| M2 | pending | macOS app target consumes PeerDropKit alongside iOS |

## Local development

```bash
# Build the package standalone
cd PeerDropKit && swift build

# Run package tests (none in M1c — tests come in M1d when files migrate)
cd PeerDropKit && swift test
```

The PeerDrop app builds + tests still flow through xcodebuild on the
`PeerDrop` scheme; xcodegen wires the local SPM package into the Xcode
project via project.yml.
