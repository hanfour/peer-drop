import XCTest
import CryptoKit
@testable import PeerDrop

@MainActor
final class SecurityPolicyStoreFetchTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        MockURLProtocol.reset()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        MockURLProtocol.reset()
        try await super.tearDown()
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func loadDevPublicKey() throws -> Data {
        let workspaceURL = URL(fileURLWithPath: #file)
            .deletingLastPathComponent() // PeerDropTests/
            .deletingLastPathComponent() // peer-drop/
        let devKeyURL = workspaceURL.appendingPathComponent("cloudflare-worker/dev-signing-key.json")
        let data = try Data(contentsOf: devKeyURL)
        let dict = try JSONDecoder().decode([String: String].self, from: data)
        guard let pubKeyBase64 = dict["public_key_base64"],
              let pubKeyData = Data(base64Encoded: pubKeyBase64) else {
            throw XCTestError(.failureWhileWaiting, userInfo: [NSLocalizedDescriptionKey: "Missing public_key_base64 in dev-signing-key.json"])
        }
        return pubKeyData
    }

    private func loadSignedBundledDefault() throws -> Data {
        let workspaceURL = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = workspaceURL.appendingPathComponent("cloudflare-worker/bundled-default-policy.signed.json")
        return try Data(contentsOf: url)
    }

    func test_init_emptyDir_returnsBundledDefault() throws {
        let store = SecurityPolicyStore(storageDirectory: tmpDir, publicKeys: [])
        XCTAssertEqual(store.current, .bundledDefault)
    }

    func test_fetch_updatesCurrent_onValidResponse() async throws {
        let pubKey = try loadDevPublicKey()
        let signedBlob = try loadSignedBundledDefault()
        MockURLProtocol.responseData = signedBlob
        MockURLProtocol.responseStatusCode = 200

        // autoStartRefresh: true (default) — exercises the Task-spawn branch for
        // coverage. The explicit fetchAndUpdate below may see count=2 if the Task
        // also runs; we only assert on store.current (idempotent) and file existence.
        let store = SecurityPolicyStore(
            storageDirectory: tmpDir,
            publicKeys: [pubKey],
            baseURL: URL(string: "https://example.com")!,
            urlSession: makeSession()
        )
        await store.fetchAndUpdate()
        // The bundled default and the fetched blob's policy are the same;
        // merged result is bundled default.
        XCTAssertEqual(store.current, .bundledDefault)
        // Cache file should now exist.
        let cacheURL = tmpDir.appendingPathComponent("crypto-policy.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path))
    }

    func test_fetch_invalidSignature_keepsCurrentAndRecordsMetric() async throws {
        let pubKey = try loadDevPublicKey()
        // Tamper the signature field → invalidates signature.
        var blobDict = try JSONSerialization.jsonObject(with: loadSignedBundledDefault()) as! [String: Any]
        blobDict["signature"] = "TAMPEREDTAMPEREDTAMPEREDTAMPERED="
        let tampered = try JSONSerialization.data(withJSONObject: blobDict, options: [.sortedKeys])
        MockURLProtocol.responseData = tampered
        MockURLProtocol.responseStatusCode = 200

        let metrics = CryptoHardeningMetrics()
        let store = SecurityPolicyStore(
            storageDirectory: tmpDir,
            publicKeys: [pubKey],
            metrics: metrics,
            baseURL: URL(string: "https://example.com")!,
            urlSession: makeSession(),
            autoStartRefresh: false
        )
        await store.fetchAndUpdate()
        // current stays at bundled (cache miss → bundled default).
        XCTAssertEqual(store.current, .bundledDefault)
        // Signature invalid was recorded.
        XCTAssertEqual(metrics.snapshot().counters["policy.signature_invalid"], 1)
    }

    func test_fetch_networkError_recordsMetric() async throws {
        let pubKey = try loadDevPublicKey()
        MockURLProtocol.responseError = NSError(domain: "test", code: -1, userInfo: nil)

        let metrics = CryptoHardeningMetrics()
        let store = SecurityPolicyStore(
            storageDirectory: tmpDir,
            publicKeys: [pubKey],
            metrics: metrics,
            baseURL: URL(string: "https://example.com")!,
            urlSession: makeSession(),
            autoStartRefresh: false
        )
        await store.fetchAndUpdate()
        XCTAssertEqual(store.current, .bundledDefault)
        XCTAssertEqual(metrics.snapshot().counters["policy.fetch_failure"], 1)
    }

    func test_fetch_invariantViolation_recordsDistinctMetric() async throws {
        // PR4-review-follow-up: parseSignedPolicy throws .invariantViolation
        // for a validly-signed blob whose policy violates a cross-field
        // invariant. fetchAndUpdate routes this to a distinct metric
        // (policy.invariant_violation), not the generic fetch_failure bucket.
        let workspaceURL = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let devKeyURL = workspaceURL.appendingPathComponent("cloudflare-worker/dev-signing-key.json")
        struct Key: Codable {
            let private_key_base64: String
            let public_key_base64: String
        }
        let keyData = try Data(contentsOf: devKeyURL)
        let key = try JSONDecoder().decode(Key.self, from: keyData)
        let privKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(base64Encoded: key.private_key_base64)!
        )
        let pubKey = Data(base64Encoded: key.public_key_base64)!

        // pruneWindow=90 < spkMaxAge=30 * 4 = 120 → invariant violation.
        let badPolicy = SecurityPolicy(
            spkMaxAgeDays: 30,
            spkExpirationBehavior: .warn,
            opkExhaustionLegacy: .proceedWithoutDH4,
            opkExhaustionStrict: .failClosed,
            opkRetryMaxAttempts: 5,
            opkRetryIntervalSeconds: 60,
            skippedKeyTTLDays: 30,
            skippedKeyMaxCount: 200,
            consumedOPKPruneWindowDays: 90
        )
        let policyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(badPolicy)) as! [String: Any]
        let payloadDict: [String: Any] = [
            "schemaVersion": 1,
            "issuedAt": 1_748_000_000,
            "expiresAt": 1_750_592_000,
            "policy": policyJSON
        ]
        let canonical = try CanonicalJSON.serialize(payloadDict)
        let signature = try privKey.signature(for: canonical).base64EncodedString()
        var blobDict = payloadDict
        blobDict["signature"] = signature
        let blob = try JSONSerialization.data(withJSONObject: blobDict, options: [.sortedKeys])
        MockURLProtocol.responseData = blob

        let metrics = CryptoHardeningMetrics()
        let store = SecurityPolicyStore(
            storageDirectory: tmpDir,
            publicKeys: [pubKey],
            metrics: metrics,
            baseURL: URL(string: "https://example.com")!,
            urlSession: makeSession(),
            autoStartRefresh: false
        )
        _ = await store.fetchAndUpdate()
        XCTAssertEqual(store.current, .bundledDefault, "invalid policy must NOT replace bundled default")
        let snap = metrics.snapshot()
        XCTAssertEqual(snap.counters["policy.invariant_violation"], 1,
                       "invariant violations must route to their dedicated metric, not policy.fetch_failure")
        XCTAssertNil(snap.counters["policy.fetch_failure"],
                     "invariant violation must NOT increment the generic fetch_failure bucket")
    }

    func test_boot_reads_cachedBlob_intoCurrent() throws {
        // Pre-populate the cache file before constructing the store.
        let signedBlob = try loadSignedBundledDefault()
        let cacheURL = tmpDir.appendingPathComponent("crypto-policy.json")
        try signedBlob.write(to: cacheURL)

        let pubKey = try loadDevPublicKey()
        let metrics = CryptoHardeningMetrics()
        let store = SecurityPolicyStore(
            storageDirectory: tmpDir,
            publicKeys: [pubKey],
            metrics: metrics
        )
        XCTAssertEqual(store.current, .bundledDefault, "cached blob has policy == bundledDefault, merge stays bundled")
        XCTAssertEqual(metrics.snapshot().counters["policy.cache_hit"], 1)
    }

    func test_fetchAndUpdate_withNilBaseURL_returnsFalse() async throws {
        // Covers the `guard let baseURL` early-return path in fetchAndUpdate.
        let store = SecurityPolicyStore(storageDirectory: tmpDir, publicKeys: [])
        // No baseURL → fetchAndUpdate returns false immediately.
        let result = await store.fetchAndUpdate()
        XCTAssertFalse(result)
    }

    func test_fetch_malformedJSON_recordsFetchFailure() async throws {
        // Sends garbage JSON so parseSignedPolicy throws .malformedJSON,
        // which falls through to the generic `catch` in fetchAndUpdate.
        MockURLProtocol.responseData = Data("{{not json}}".utf8)
        MockURLProtocol.responseStatusCode = 200

        let pubKey = try loadDevPublicKey()
        let metrics = CryptoHardeningMetrics()
        let store = SecurityPolicyStore(
            storageDirectory: tmpDir,
            publicKeys: [pubKey],
            metrics: metrics,
            baseURL: URL(string: "https://example.com")!,
            urlSession: makeSession(),
            autoStartRefresh: false
        )
        let succeeded = await store.fetchAndUpdate()
        XCTAssertFalse(succeeded)
        XCTAssertEqual(metrics.snapshot().counters["policy.fetch_failure"], 1,
                       "malformed JSON from server must route to the generic fetch_failure bucket")
    }

    func test_fetch_non2xxResponse_recordsFetchFailure() async throws {
        let pubKey = try loadDevPublicKey()
        // 500 status → non-2xx guard triggers policyFetchFailure.
        MockURLProtocol.responseData = Data()
        MockURLProtocol.responseStatusCode = 500

        let metrics = CryptoHardeningMetrics()
        let store = SecurityPolicyStore(
            storageDirectory: tmpDir,
            publicKeys: [pubKey],
            metrics: metrics,
            baseURL: URL(string: "https://example.com")!,
            urlSession: makeSession(),
            autoStartRefresh: false
        )
        let succeeded = await store.fetchAndUpdate()
        XCTAssertFalse(succeeded)
        XCTAssertEqual(metrics.snapshot().counters["policy.fetch_failure"], 1)
    }

    func test_fetch_unsupportedSchemaVersion_recordsMetric() async throws {
        // Send a blob with schemaVersion = 999 (but valid base64 signature shape
        // so we hit the version gate, not the JSON-parse gate).
        var blobDict = try JSONSerialization.jsonObject(with: loadSignedBundledDefault()) as! [String: Any]
        blobDict["schemaVersion"] = 999
        let tampered = try JSONSerialization.data(withJSONObject: blobDict, options: [.sortedKeys])
        MockURLProtocol.responseData = tampered
        MockURLProtocol.responseStatusCode = 200

        let pubKey = try loadDevPublicKey()
        let metrics = CryptoHardeningMetrics()
        let store = SecurityPolicyStore(
            storageDirectory: tmpDir,
            publicKeys: [pubKey],
            metrics: metrics,
            baseURL: URL(string: "https://example.com")!,
            urlSession: makeSession(),
            autoStartRefresh: false
        )
        let succeeded = await store.fetchAndUpdate()
        XCTAssertFalse(succeeded)
        XCTAssertEqual(metrics.snapshot().counters["policy.version_unsupported"], 1)
    }

    // MARK: - Coverage-gap closers (loadFromCacheOrBundled + fetchAndUpdate paths)

    func test_boot_expiredCache_recordsExpiredInUseMetric() throws {
        // Build and sign a blob with expiresAt in the past.
        let workspaceURL = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        struct Key: Codable { let private_key_base64: String; let public_key_base64: String }
        let key = try JSONDecoder().decode(Key.self, from: try Data(contentsOf: workspaceURL.appendingPathComponent("cloudflare-worker/dev-signing-key.json")))
        let privKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(base64Encoded: key.private_key_base64)!)
        let pubKey = Data(base64Encoded: key.public_key_base64)!

        let policy = SecurityPolicy.bundledDefault
        let policyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(policy)) as! [String: Any]
        // expiresAt = 1 (far in the past)
        let payloadDict: [String: Any] = [
            "schemaVersion": 1,
            "issuedAt": 0,
            "expiresAt": 1,
            "policy": policyJSON
        ]
        let canonical = try CanonicalJSON.serialize(payloadDict)
        let signature = try privKey.signature(for: canonical).base64EncodedString()
        var blobDict = payloadDict
        blobDict["signature"] = signature
        let expiredBlob = try JSONSerialization.data(withJSONObject: blobDict, options: [.sortedKeys])

        let cacheURL = tmpDir.appendingPathComponent("crypto-policy.json")
        try expiredBlob.write(to: cacheURL)

        let metrics = CryptoHardeningMetrics()
        _ = SecurityPolicyStore(
            storageDirectory: tmpDir,
            publicKeys: [pubKey],
            metrics: metrics
        )
        let snap = metrics.snapshot()
        XCTAssertEqual(snap.counters["policy.cache_hit"], 1, "expired-but-valid blob still records a cache hit")
        XCTAssertEqual(snap.counters["policy.expired_in_use"], 1, "expired blob must record policyExpiredInUse metric")
    }

    func test_boot_corruptCache_fallsBackToBundledDefault() throws {
        // Write garbage bytes as the cache file.
        let cacheURL = tmpDir.appendingPathComponent("crypto-policy.json")
        try Data("not valid json at all !!@#$".utf8).write(to: cacheURL)

        let pubKey = try loadDevPublicKey()
        let metrics = CryptoHardeningMetrics()
        let store = SecurityPolicyStore(
            storageDirectory: tmpDir,
            publicKeys: [pubKey],
            metrics: metrics
        )
        // Corrupt cache → catch block → bundledDefault (no cache-hit metric).
        XCTAssertEqual(store.current, .bundledDefault)
        XCTAssertNil(metrics.snapshot().counters["policy.cache_hit"], "corrupt cache must NOT record a cache hit")
    }

    func test_fetch_outOfBoundsPolicy_recordsMetricAndClamps() async throws {
        // Build and sign a policy where spkMaxAgeDays is above the max bound.
        let workspaceURL = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        struct Key: Codable { let private_key_base64: String; let public_key_base64: String }
        let key = try JSONDecoder().decode(Key.self, from: try Data(contentsOf: workspaceURL.appendingPathComponent("cloudflare-worker/dev-signing-key.json")))
        let privKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(base64Encoded: key.private_key_base64)!)
        let pubKey = Data(base64Encoded: key.public_key_base64)!

        // spkMaxAgeDays = 9999 exceeds SecurityPolicyBounds.maxSPKMaxAgeDays.
        // consumedOPKPruneWindowDays must stay ≥ spkMaxAge*4 to pass invariants:
        // use the clamped max (365) * 4 = 1460 but the invariant checks BEFORE
        // clamping, so we need a value that keeps the invariant on the RAW policy.
        // Actually invariant is pruneWindow ≥ spkMaxAge×4 on decoded values,
        // so with spkMaxAge=9999, pruneWindow must be ≥ 39996. We also want to
        // trigger policyValueOutOfBounds (violations.isEmpty == false) which just
        // requires ANY out-of-range field — keep spkMaxAge big enough to violate
        // bounds but satisfy invariant via a big pruneWindow too.
        //
        // Simpler: use spkMaxAgeDays=999, consumedOPKPruneWindowDays=9999
        // which satisfies invariant (9999 ≥ 999*4=3996) but both exceed bounds.
        let outOfBoundsPolicy = SecurityPolicy(
            spkMaxAgeDays: 999,
            spkExpirationBehavior: .warn,
            opkExhaustionLegacy: .proceedWithoutDH4,
            opkExhaustionStrict: .failClosed,
            opkRetryMaxAttempts: 5,
            opkRetryIntervalSeconds: 60,
            skippedKeyTTLDays: 30,
            skippedKeyMaxCount: 200,
            consumedOPKPruneWindowDays: 9999
        )
        let policyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(outOfBoundsPolicy)) as! [String: Any]
        let payloadDict: [String: Any] = [
            "schemaVersion": 1,
            "issuedAt": 1_748_000_000,
            "expiresAt": 1_850_000_000,
            "policy": policyJSON
        ]
        let canonical = try CanonicalJSON.serialize(payloadDict)
        let signature = try privKey.signature(for: canonical).base64EncodedString()
        var blobDict = payloadDict
        blobDict["signature"] = signature
        let blob = try JSONSerialization.data(withJSONObject: blobDict, options: [.sortedKeys])
        MockURLProtocol.responseData = blob
        MockURLProtocol.responseStatusCode = 200

        let metrics = CryptoHardeningMetrics()
        let store = SecurityPolicyStore(
            storageDirectory: tmpDir,
            publicKeys: [pubKey],
            metrics: metrics,
            baseURL: URL(string: "https://example.com")!,
            urlSession: makeSession(),
            autoStartRefresh: false
        )
        let succeeded = await store.fetchAndUpdate()
        XCTAssertTrue(succeeded, "out-of-bounds values are clamped, fetch must still succeed")
        XCTAssertEqual(metrics.snapshot().counters["policy.value_out_of_bounds"], 1,
                       "out-of-range field must record policyValueOutOfBounds metric")
        XCTAssertEqual(metrics.snapshot().counters["policy.fetch_success"], 1)
    }

    func test_parseSignedPolicy_invalidBase64Signature_throwsInvalidSignature() throws {
        // Covers the `guard let sigBytes = Data(base64Encoded: ...)` path in
        // parseSignedPolicy (distinct from a valid-base64 but wrong-key tamper).
        var blobDict = try JSONSerialization.jsonObject(with: loadSignedBundledDefault()) as! [String: Any]
        blobDict["signature"] = "!!!NOT BASE64!!!"   // cannot be decoded as base64
        let tampered = try JSONSerialization.data(withJSONObject: blobDict, options: [.sortedKeys])
        let pubKey = try loadDevPublicKey()
        XCTAssertThrowsError(
            try SecurityPolicyStore.parseSignedPolicy(tampered, publicKeys: [pubKey])
        ) { error in
            XCTAssertEqual(error as? SecurityPolicyStore.ParseError, .invalidSignature)
        }
    }
}
