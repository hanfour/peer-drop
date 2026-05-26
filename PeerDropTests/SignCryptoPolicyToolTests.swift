import XCTest
import CryptoKit
import PeerDropSecurity
@testable import PeerDrop

final class SignCryptoPolicyToolTests: XCTestCase {

    /// Verifies that the committed bundled-default signed blob has a valid
    /// signature against the dev public key from project.yml's Info.plist.
    /// Acts as a CI tripwire if anyone edits the signed blob by hand without
    /// re-running the tool.
    func test_bundledDefaultSignedBlob_verifiesAgainstBundledPublicKey() throws {
        // Locate cloudflare-worker/bundled-default-policy.signed.json on disk
        // (not in the test bundle — it's not a test resource). Walk up from
        // the test's bundle path to find the repo root.
        let workspaceURL = try repoRoot()
        let signedURL = workspaceURL.appendingPathComponent("cloudflare-worker/bundled-default-policy.signed.json")
        let data = try Data(contentsOf: signedURL)

        // Read the dev public key from project.yml's Info.plist contents — the
        // app bundle has it as CryptoPolicyPublicKeys.
        let bundledKeys = (Bundle.main.object(forInfoDictionaryKey: "CryptoPolicyPublicKeys") as? [String])?
            .compactMap { Data(base64Encoded: $0) } ?? []
        // If the test runs without the app bundle (e.g., SwiftPM CLI tests), fall
        // back to reading the dev key file directly.
        let keys: [Data]
        if !bundledKeys.isEmpty {
            keys = bundledKeys
        } else {
            let devKeyURL = workspaceURL.appendingPathComponent("cloudflare-worker/dev-signing-key.json")
            let devKey = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: devKeyURL))
            keys = [Data(base64Encoded: devKey["public_key_base64"]!)!]
        }

        XCTAssertGreaterThanOrEqual(keys.count, 1, "no public keys available — Info.plist or dev-signing-key.json broken")

        let result = try SecurityPolicyStore.parseSignedPolicy(data, publicKeys: keys)
        XCTAssertEqual(result.schemaVersion, 1)
        XCTAssertEqual(result.policy, .bundledDefault)
    }

    /// Returns the repo root by walking up from the compile-time path of
    /// this source file (`#file`). Because `#file` is resolved at compile time
    /// to the absolute path of the source file on the build machine, this
    /// approach is immune to the deep simulator sandbox paths that trip up
    /// bundle-URL-based walks.
    ///
    /// `#file` = `.../PeerDropTests/SignCryptoPolicyToolTests.swift`
    /// We walk up twice (test file → PeerDropTests → repo root).
    private func repoRoot(file: StaticString = #file) throws -> URL {
        // Start from the directory that contains this source file.
        var dir = URL(fileURLWithPath: "\(file)", isDirectory: false)
            .deletingLastPathComponent()   // PeerDropTests/
            .deletingLastPathComponent()   // repo root
        // Safety: verify cloudflare-worker/ exists here.
        let candidate = dir.appendingPathComponent("cloudflare-worker", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir),
              isDir.boolValue else {
            // Fallback: walk up from bundle URL (original strategy, extended to 20 hops).
            dir = Bundle(for: type(of: self)).bundleURL
            for _ in 0..<20 {
                dir.deleteLastPathComponent()
                let c = dir.appendingPathComponent("cloudflare-worker", isDirectory: true)
                var d: ObjCBool = false
                if FileManager.default.fileExists(atPath: c.path, isDirectory: &d), d.boolValue {
                    return dir
                }
            }
            throw NSError(domain: "test", code: -1, userInfo: [NSLocalizedDescriptionKey: "cannot find repo root from \(Bundle(for: type(of: self)).bundleURL.path)"])
        }
        return dir
    }
}
