import Foundation
import Combine
import CryptoKit

/// Boot-time policy loader and async refresh coordinator.
///
/// `current` is initialized synchronously from a cached signed-policy file
/// (verified on disk) or the bundled default. After init, if `baseURL` is
/// supplied, an async fetch + 24h periodic refresh task is spawned to keep
/// the policy up-to-date while the app is running.
///
/// `@MainActor` so SwiftUI consumers can subscribe to `$current` directly
/// without dispatch dancing.
@MainActor
public final class SecurityPolicyStore: ObservableObject {

    @Published public private(set) var current: SecurityPolicy

    let storageDirectory: URL
    let publicKeys: [Data]   // Ed25519 public keys for signature verification
    let metrics: CryptoHardeningMetrics?
    private let baseURL: URL?
    private let urlSession: URLSession
    private var refreshTask: Task<Void, Never>?

    public init(
        storageDirectory: URL,
        publicKeys: [Data],
        metrics: CryptoHardeningMetrics? = nil,
        baseURL: URL? = nil,
        urlSession: URLSession = .shared
    ) {
        self.storageDirectory = storageDirectory
        self.publicKeys = publicKeys
        self.metrics = metrics
        self.baseURL = baseURL
        self.urlSession = urlSession
        // Synchronous boot load — read + verify cache, or fall back to bundled default.
        self.current = SecurityPolicyStore.loadFromCacheOrBundled(
            directory: storageDirectory,
            publicKeys: publicKeys,
            metrics: metrics
        )
        // Schedule the async fetch + adaptive refresh loop if a baseURL is
        // configured. Tests that don't want the network leg leave baseURL nil.
        //
        // The loop runs at 24h cadence on success. After a failure, switches to
        // exponential backoff (1m → 2m → 4m → ... capped at 1h) until the next
        // success resets the counter. This means a transient boot-time network
        // hiccup doesn't strand the client on bundled defaults for 24h.
        if baseURL != nil {
            self.refreshTask = Task { [weak self] in
                var consecutiveFailures = 0
                // Initial fetch.
                if let succeeded = await self?.fetchAndUpdate() {
                    consecutiveFailures = succeeded ? 0 : 1
                }
                while !Task.isCancelled {
                    let intervalSeconds: UInt64
                    if consecutiveFailures == 0 {
                        intervalSeconds = 24 * 3600              // happy path: once per day
                    } else {
                        let backoff = min(60 * (1 << min(consecutiveFailures - 1, 6)), 3600)
                        intervalSeconds = UInt64(backoff)        // 60s → 120s → ... → 3600s cap
                    }
                    try? await Task.sleep(nanoseconds: intervalSeconds * 1_000_000_000)
                    if Task.isCancelled { break }
                    if let succeeded = await self?.fetchAndUpdate() {
                        consecutiveFailures = succeeded ? 0 : consecutiveFailures + 1
                    }
                }
            }
        }
    }

    deinit {
        refreshTask?.cancel()
    }
}

// MARK: - Fetch + Cache

extension SecurityPolicyStore {

    /// One-shot async fetch + parse + publish. Called at boot (after sync
    /// cache load) and from the periodic refresh loop. Returns `true` on a
    /// fully-successful update, `false` on any error path (the caller's
    /// backoff logic uses this to decide the next sleep interval).
    @discardableResult
    public func fetchAndUpdate() async -> Bool {
        guard let baseURL = baseURL else { return false }
        let url = baseURL.appendingPathComponent("v2/config/crypto-policy")

        let data: Data
        do {
            let (responseData, response) = try await urlSession.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                metrics?.record(.policyFetchFailure)
                return false
            }
            data = responseData
        } catch {
            metrics?.record(.policyFetchFailure)
            return false
        }

        // Parse + verify.
        let parsed: SignedCryptoPolicy
        do {
            parsed = try SecurityPolicyStore.parseSignedPolicy(data, publicKeys: publicKeys)
        } catch SecurityPolicyStore.ParseError.invalidSignature {
            metrics?.record(.policySignatureInvalid)
            return false
        } catch SecurityPolicyStore.ParseError.unsupportedSchemaVersion {
            metrics?.record(.policyVersionUnsupported)
            return false
        } catch SecurityPolicyStore.ParseError.invariantViolation {
            // Validly-signed blob with a cross-field invariant violation —
            // distinct from network failures (operator misconfiguration or
            // signed-key-with-bad-payload). PR4-review-follow-up event.
            metrics?.record(.policyInvariantViolation)
            return false
        } catch {
            metrics?.record(.policyFetchFailure)
            return false
        }

        // Apply local bounds clamping. Telemetry for any out-of-range field.
        let violations = SecurityPolicyBounds.violations(parsed.policy)
        if !violations.isEmpty {
            metrics?.record(.policyValueOutOfBounds)
        }
        let clamped = SecurityPolicyBounds.clamp(parsed.policy)

        // Stronger-of-two merge with bundled default. Worker can only strengthen.
        let merged = SecurityPolicy.merged(local: .bundledDefault, remote: clamped)

        // Persist the original signed blob (NOT the merged result) so the next
        // boot can re-verify the signature. Merge is recomputed each boot.
        await persistCache(data)

        // Already on @MainActor — update current directly.
        self.current = merged
        metrics?.record(.policyFetchSuccess)
        return true
    }

    private func persistCache(_ blob: Data) async {
        let cacheURL = storageDirectory.appendingPathComponent("crypto-policy.json")
        try? blob.write(to: cacheURL, options: .atomic)
    }

    /// Synchronous boot-time cache read. Called from `init`. Reads the cached
    /// signed blob from disk, verifies the signature, applies clamp + merge,
    /// and returns the resulting policy. Any error path falls back to bundled
    /// default.
    fileprivate static func loadFromCacheOrBundled(
        directory: URL,
        publicKeys: [Data],
        metrics: CryptoHardeningMetrics?
    ) -> SecurityPolicy {
        let cacheURL = directory.appendingPathComponent("crypto-policy.json")
        guard let cached = try? Data(contentsOf: cacheURL) else {
            // No cache — fall back to bundled default (no cache-hit recorded).
            return .bundledDefault
        }
        do {
            let parsed = try parseSignedPolicy(cached, publicKeys: publicKeys)
            metrics?.record(.policyCacheHit)
            // Track expiry as a sample (used by the eventual UI status panel).
            if parsed.expiresAt < UInt64(Date().timeIntervalSince1970) {
                metrics?.record(.policyExpiredInUse)
            }
            let clamped = SecurityPolicyBounds.clamp(parsed.policy)
            return SecurityPolicy.merged(local: .bundledDefault, remote: clamped)
        } catch {
            // Cache is corrupt / signature invalid / etc. — bundled default.
            return .bundledDefault
        }
    }
}

// MARK: - parseSignedPolicy

extension SecurityPolicyStore {

    public enum ParseError: Error, Equatable {
        case malformedJSON
        case invalidSignature
        case unsupportedSchemaVersion(Int)
        case invariantViolation
    }

    /// Verify and parse a signed-policy blob. Returns the decoded
    /// `SignedCryptoPolicy` on success; throws `ParseError` on the first
    /// failure encountered (in order: JSON parse → schema version → signature → invariants).
    ///
    /// `publicKeys` is the list of trusted Ed25519 verification keys
    /// (typically from `Info.plist` `CryptoPolicyPublicKeys`). The signature
    /// is accepted if ANY key in the list verifies it — enables in-flight
    /// key rotation by shipping a build that trusts both the old and new
    /// public keys for a transition window.
    ///
    /// Empty `publicKeys` (no trust roots configured) → `invalidSignature`.
    /// This matches the PR1 placeholder-handling intent: until PR4 ships real
    /// keys to the bundle, the parse path refuses remote policies entirely
    /// rather than silently falling back to "no signature check".
    public nonisolated static func parseSignedPolicy(
        _ data: Data,
        publicKeys: [Data]
    ) throws -> SignedCryptoPolicy {
        // 1. Parse JSON envelope.
        let decoded: SignedCryptoPolicy
        do {
            decoded = try JSONDecoder().decode(SignedCryptoPolicy.self, from: data)
        } catch {
            throw ParseError.malformedJSON
        }

        // 2. Schema version gate.
        guard decoded.schemaVersion == 1 else {
            throw ParseError.unsupportedSchemaVersion(decoded.schemaVersion)
        }

        // 3. Signature verification.
        // Reconstruct the signed payload (everything except the signature) as
        // canonical JSON, then try each public key in turn.
        let policyAsJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded.policy))
        let payloadDict: [String: Any] = [
            "schemaVersion": decoded.schemaVersion,
            "issuedAt": decoded.issuedAt,
            "expiresAt": decoded.expiresAt,
            "policy": policyAsJSON
        ]
        let canonical: Data
        do {
            canonical = try CanonicalJSON.serialize(payloadDict)
        } catch {
            // Should not happen: SignedCryptoPolicy is well-typed Codable.
            throw ParseError.malformedJSON
        }

        guard let sigBytes = Data(base64Encoded: decoded.signature) else {
            throw ParseError.invalidSignature
        }

        var matched = false
        for pkBytes in publicKeys {
            if let pk = try? Curve25519.Signing.PublicKey(rawRepresentation: pkBytes),
               pk.isValidSignature(sigBytes, for: canonical) {
                matched = true
                break
            }
        }
        guard matched else {
            throw ParseError.invalidSignature
        }

        // 4. Cross-field invariants (pruneWindow ≥ spkMaxAge × 4, etc.)
        do {
            try decoded.policy.validateInvariants()
        } catch {
            throw ParseError.invariantViolation
        }

        return decoded
    }
}
