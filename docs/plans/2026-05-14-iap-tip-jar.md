# IAP tip jar prototype (Phase J)

User-facing monetization for PeerDrop. Three consumable in-app
purchases functioning as a tip jar — explicitly NOT gating any
existing feature. Aligns with the v5.3 product positioning decision:
"privacy-first P2P file transfer / chat as the core, pet system as a
value-add" — paying users get nothing extra functionally; they're
expressing gratitude for a free app.

## Goals

- Test the wallet-out willingness of the existing user base without
  redesigning anyone's experience.
- Land the StoreKit 2 integration patterns once, so any future paid
  feature (real Pro tier, account-bound subscription, etc.) has the
  scaffolding in place.
- Honest framing — "buy us a coffee", not "unlock premium". Users who
  decline pay nothing, see nothing different.

## Non-goals

- **No feature gating.** Files, chat, pets, secure channel, App
  Attest — all stay free regardless of tip status.
- **No subscriptions.** Tips are consumable IAPs; bought once, no
  expiry, no monthly hit.
- **No leaderboard / public donor list.** Tips are private. No PII
  collected by PeerDrop beyond what Apple's payment flow already
  surfaces to the App Store side.
- **No retroactive thanks.** Existing users on v5.0–v5.3 see no tip
  surface until they upgrade to whichever version this ships in.

## Product catalogue

Three Consumable products at standard Apple tier pricing:

| Product ID | Tier | USD | Label |
|---|---|---|---|
| `com.hanfour.peerdrop.tip.small`  | Tier 2  | $1.99 | Buy us a coffee ☕ |
| `com.hanfour.peerdrop.tip.medium` | Tier 5  | $4.99 | Buy us lunch 🍱 |
| `com.hanfour.peerdrop.tip.large`  | Tier 10 | $9.99 | Big thank you 🎉 |

(Localized display name + description live in App Store Connect per
product. The IDs are stable so even renaming the label later doesn't
break receipts.)

## Architecture

```
PeerDrop/
├── Purchase/
│   └── TipJarManager.swift     ← StoreKit 2 client wrapper (actor)
└── UI/
    └── Settings/
        └── TipJarSection.swift ← SwiftUI section rendered in Settings
```

`TipJarManager` is an `actor` singleton (matches `DeviceTokenManager`'s
shape):

```swift
@MainActor
final class TipJarManager: ObservableObject {
    static let shared = TipJarManager()

    @Published private(set) var products: [Product] = []
    @Published private(set) var purchasingProductID: String?
    @Published private(set) var lastError: String?
    @Published var lastSucceededTipName: String?  // drives toast

    func loadProducts() async
    func purchase(_ product: Product) async
    func handleTransactions() async   // background task: process Transaction.updates
}
```

State machine:
- App launch → `loadProducts()` once, lazily
- User taps tip → `purchase(product)` → StoreKit purchase sheet appears
- Apple confirms → `Transaction.updates` yields a result → verify →
  finish → set `lastSucceededTipName` + post haptic
- Failure → set `lastError`, surface as alert

`Transaction.updates` is processed in a long-running task started at
app launch so out-of-band updates (refund, replay) get processed too.

## UI

Settings → new "Support PeerDrop" section above Notifications:

```
┌─ Support PeerDrop ─────────────────────┐
│                                         │
│  ☕ $1.99    🍱 $4.99    🎉 $9.99      │
│  Coffee     Lunch       Big thank you   │
│                                         │
│  PeerDrop is free and ad-free. Tips     │
│  go to the developer — they don't       │
│  unlock anything, they just say thanks. │
└─────────────────────────────────────────┘
```

Tap a card → StoreKit purchase sheet (Apple's UI; cancellable).
Success → haptic + toast "Thanks for the coffee!" / "Thanks for
lunch!" / "Thanks for the big tip!" via existing `latestToast` infra
in `ConnectionManager`.

## Required operator actions (App Store Connect side)

Code in this Phase ships ready-to-use the moment these complete:

1. **Sign the Paid Applications Agreement** (App Store Connect →
   Business → Agreements). Required even for tips. Includes tax + bank
   info forms. **Operator action, not automatable.**
2. **Create the 3 IAPs:**
   - App Store Connect → PeerDrop → In-App Purchases → +
   - Type: Consumable
   - Reference Name: matches the table above (internal-only)
   - Product ID: as table
   - Pricing: tier 2 / 5 / 10
   - Localized name + description: per-language (5 langs to match
     `fastlane/metadata/`)
   - Review screenshot: 1024×1024 mock of the tip card UI
3. **Submit IAPs for review** alongside or before the next app
   version that ships the tip UI.

## Privacy posture

- Apple's payment sheet collects card / Apple ID info. PeerDrop never
  sees it.
- No "tipped" flag persisted by us — we don't know who tipped, only
  StoreKit does. (Apple receipts could in principle be replayed to
  verify, but we don't have a server-side endpoint for that and
  don't intend to.)
- Privacy Manifest stays unchanged. Apple's IAP framework is excluded
  from the "data collected" reporting since it's their flow.
- Tip section renders the price in the user's local currency via
  `Product.displayPrice`; we never store or transmit those values.

## Localization

5-language strings to add to `Localizable.xcstrings`:

- "Support PeerDrop"
- "Buy us a coffee", "Buy us lunch", "Big thank you"
- "PeerDrop is free and ad-free. Tips go to the developer — they don't unlock anything, they just say thanks."
- "Thanks for the coffee!", "Thanks for lunch!", "Thanks for the big tip!"
- "Purchase failed: %@"
- "Loading products…"

Product display names + descriptions live in App Store Connect (one
entry per locale). The 5 langs we already ship (`en-US`, `zh-Hant`,
`zh-Hans`, `ja`, `ko`) all need entries.

## Verification

- Unit tests for `TipJarManager` state transitions via mock
  `Transaction.updates` and `Product.purchase` stubs.
- Manual smoke test on TestFlight build:
  - Load settings → see 3 cards with prices
  - Tap → StoreKit sheet appears
  - Cancel → no state change, no toast
  - Confirm in sandbox → toast appears, no feature change anywhere
  - Repeat purchase (consumable; should succeed twice)

## Out of scope for this prototype

These are queued for "if tips actually take off" follow-ups:

- Real Pro tier with feature gating (multi-device library, history
  search, batch transfer, etc.)
- Subscription model
- iCloud-synced "tipped" badge across devices
- Cross-platform companion (macOS app would need its own IAP setup)

## Estimated work

- J1 TipJarManager: ~3 hr
- J2 UI: ~2 hr
- J3 localization: ~1 hr (5 langs × ~6 strings)
- J4 tests: ~2 hr
- J5 commit + push: ~30 min

Total iOS work: ~1 day. Plus operator's ASC setup which is uncertain
(could be 30 min if forms are pre-filled, could be a week if tax info
needs gathering).
