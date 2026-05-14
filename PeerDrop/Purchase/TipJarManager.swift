import Foundation
import StoreKit
import os.log

/// In-app tip jar client (StoreKit 2). Three consumable products that
/// don't gate any feature — purely an "if you want to thank us, here's
/// the button". See docs/plans/2026-05-14-iap-tip-jar.md for the
/// product strategy + ASC operator setup.
///
/// The three product identifiers MUST stay in sync with the IAPs
/// configured in App Store Connect. Renaming the on-screen label later
/// is fine; renaming the IDs breaks every existing receipt.
@MainActor
final class TipJarManager: ObservableObject {

    static let shared = TipJarManager()

    static let productIDs: [String] = [
        "com.hanfour.peerdrop.tip.small",
        "com.hanfour.peerdrop.tip.medium",
        "com.hanfour.peerdrop.tip.large",
    ]

    private let logger = Logger(subsystem: "com.hanfour.peerdrop", category: "TipJarManager")

    /// Loaded once via `loadProducts()`; kept in display order matching
    /// `productIDs` so the UI can render small → medium → large.
    @Published private(set) var products: [Product] = []

    /// True while waiting for any product list response or purchase
    /// confirmation. Drives spinner state on the Settings card.
    @Published private(set) var isWorking: Bool = false

    /// Product currently in the middle of a purchase. Nil between
    /// purchase attempts. UI uses this to dim non-purchasing cards.
    @Published private(set) var purchasingProductID: String?

    /// Last fatal error from a load / purchase / verification path.
    /// Surfaced as an alert; cleared after the user dismisses it.
    @Published var lastError: String?

    /// Set the moment a purchase succeeds. The Settings card watches
    /// this to fire the "Thanks!" toast + haptic, then nils it out
    /// after the toast settles. The String is the product's
    /// `displayName` for human-readable thanks text.
    @Published var lastSucceededTipName: String?

    /// Background task that drains `Transaction.updates`. Started by
    /// `startObservingTransactions()` at app launch. Holds Apple-
    /// initiated updates that arrive out-of-band (refunds, family
    /// sharing, replay of a stuck transaction).
    private var observerTask: Task<Void, Never>?

    private init() {}

    // MARK: - Lifecycle

    /// Begin draining `Transaction.updates`. Idempotent — calling
    /// twice is harmless because the existing task is cancelled and
    /// replaced.
    func startObservingTransactions() {
        observerTask?.cancel()
        observerTask = Task { [weak self] in
            for await result in Transaction.updates {
                await self?.handleTransactionResult(result)
            }
        }
    }

    deinit {
        observerTask?.cancel()
    }

    // MARK: - Loading

    /// Fetch the three products from the App Store. Safe to call
    /// repeatedly; populates `products` only on success. Failure
    /// surfaces via `lastError` and leaves `products` unchanged so
    /// transient failures don't blank the UI.
    func loadProducts() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let fetched = try await Product.products(for: Self.productIDs)
            // Keep the display order stable across launches: order by
            // our `productIDs` array, not whatever order the App Store
            // returns. (Apple's order has been observed to vary.)
            let order = Dictionary(
                uniqueKeysWithValues: Self.productIDs.enumerated().map { ($0.element, $0.offset) }
            )
            products = fetched.sorted { (a, b) in
                (order[a.id] ?? Int.max) < (order[b.id] ?? Int.max)
            }
            logger.info("Loaded \(self.products.count, privacy: .public) tip products")
        } catch {
            logger.warning("Tip product load failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
    }

    // MARK: - Purchase

    /// Initiate the StoreKit purchase sheet for `product`. The flow:
    ///   1. Set `purchasingProductID` so the UI dims other cards
    ///   2. Await Apple's sheet outcome
    ///   3. On `.success(verification)`: verify, finish the
    ///      transaction, set `lastSucceededTipName`
    ///   4. On `.userCancelled`: silently return (not an error)
    ///   5. On `.pending`: surface a neutral message (waiting on
    ///      parental approval / SCA / etc.)
    ///   6. On verification failure: surface `lastError`
    func purchase(_ product: Product) async {
        purchasingProductID = product.id
        defer { purchasingProductID = nil }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                lastSucceededTipName = product.displayName
                logger.info("Tip purchased: \(product.id, privacy: .public)")
                await transaction.finish()
            case .userCancelled:
                // Not an error path — user changed their mind.
                logger.info("Tip cancelled by user: \(product.id, privacy: .public)")
            case .pending:
                lastError = String(localized: "Purchase pending approval. We'll get notified when it clears.")
            @unknown default:
                lastError = String(localized: "Unknown purchase result.")
            }
        } catch {
            logger.warning("Tip purchase failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
    }

    // MARK: - Helpers

    /// Out-of-band transaction processor. Apple sends a `Transaction`
    /// here when a purchase confirms via System Settings → Subscriptions
    /// → Restore, a Family Sharing peer purchases, or a previously-
    /// pending transaction finally clears. We just verify + finish so
    /// it doesn't sit in the queue, but DON'T fire the success toast
    /// because the user may not be in the app and a flash banner would
    /// be jarring.
    private func handleTransactionResult(_ result: VerificationResult<Transaction>) async {
        do {
            let transaction = try checkVerified(result)
            await transaction.finish()
            logger.info("Processed out-of-band tip transaction: \(transaction.productID, privacy: .public)")
        } catch {
            logger.warning("Out-of-band transaction verification failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Throws if Apple's cryptographic verification fails. This catches
    /// the rare-but-real case of a tampered/forged transaction blob.
    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error):
            throw error
        case .verified(let value):
            return value
        }
    }
}
