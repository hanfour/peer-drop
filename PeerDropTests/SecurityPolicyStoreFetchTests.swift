import XCTest
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
            urlSession: makeSession()
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
            urlSession: makeSession()
        )
        await store.fetchAndUpdate()
        XCTAssertEqual(store.current, .bundledDefault)
        XCTAssertEqual(metrics.snapshot().counters["policy.fetch_failure"], 1)
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
}
