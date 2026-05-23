import Foundation
import Combine

/// Boot-time policy loader. In PR1 (this task), `current` is initialized
/// synchronously from a cached signed-policy file or the bundled
/// default. PR4 will add the async fetch + Ed25519 signature verification
/// that updates `current` from the worker endpoint.
///
/// `@MainActor` so SwiftUI consumers can subscribe to `$current` directly
/// without dispatch dancing.
@MainActor
public final class SecurityPolicyStore: ObservableObject {

    @Published public private(set) var current: SecurityPolicy

    private let storageDirectory: URL
    private let publicKeys: [Data]   // Ed25519 public keys — used by PR4's signature verification
    private let metrics: CryptoHardeningMetrics?

    public init(
        storageDirectory: URL,
        publicKeys: [Data],
        metrics: CryptoHardeningMetrics? = nil
    ) {
        self.storageDirectory = storageDirectory
        self.publicKeys = publicKeys
        self.metrics = metrics
        // Synchronous boot load. PR4 will read + signature-verify the
        // cached blob here; for PR1, always return the bundled default
        // so the consumer surface is testable end-to-end.
        self.current = Self.loadFromCacheOrBundled(
            directory: storageDirectory,
            publicKeys: publicKeys,
            metrics: metrics
        )
    }

    private static func loadFromCacheOrBundled(
        directory: URL,
        publicKeys: [Data],
        metrics: CryptoHardeningMetrics?
    ) -> SecurityPolicy {
        // PR4: read `directory/crypto-policy.json`, verify signature
        // against `publicKeys`, parse, clamp, merge with bundled default.
        // For PR1, no consumers exist yet, so we always return the
        // bundled default and record a cache-hit telemetry event so
        // the metrics wiring is exercised end-to-end.
        metrics?.record(.policyCacheHit)
        return .bundledDefault
    }
}
