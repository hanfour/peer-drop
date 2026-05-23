import XCTest
@testable import PeerDrop

final class PolicyFuzzTests: XCTestCase {

    func test_fuzz_parseSignedPolicy_neverCrashes() throws {
        // Load the dev-signed bundled-default blob as the fuzz seed.
        let workspaceURL = URL(fileURLWithPath: #file)
            .deletingLastPathComponent() // Fuzz/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // CryptoTestKit/
            .deletingLastPathComponent() // PeerDropTests/
            .deletingLastPathComponent() // peer-drop/
        let signedURL = workspaceURL.appendingPathComponent("cloudflare-worker/bundled-default-policy.signed.json")
        let validFixture = try Data(contentsOf: signedURL)

        // Load the dev public key so the signature-verification branch is
        // exercised on the small fraction of mutations that don't break JSON.
        let devKeyURL = workspaceURL.appendingPathComponent("cloudflare-worker/dev-signing-key.json")
        let devKey = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: devKeyURL))
        let pubKey = Data(base64Encoded: devKey["public_key_base64"]!)!

        FuzzHarness.run(
            target: validFixture,
            iterations: 10_000,
            seed: 0xDEADBEEF,
            operators: FuzzHarness.Mutator.allCases
        ) { mutated in
            // Must never crash, hang, or throw an unexpected error.
            do {
                _ = try SecurityPolicyStore.parseSignedPolicy(mutated, publicKeys: [pubKey])
                // If parse succeeded, the input happened to still be valid —
                // that's fine, no assertion needed.
            } catch SecurityPolicyStore.ParseError.malformedJSON,
                    SecurityPolicyStore.ParseError.invalidSignature,
                    SecurityPolicyStore.ParseError.unsupportedSchemaVersion,
                    SecurityPolicyStore.ParseError.invariantViolation {
                // Expected error categories — fall through.
            } catch {
                XCTFail("Unexpected error type from parseSignedPolicy on mutated input: \(error)")
            }
        }
    }
}
