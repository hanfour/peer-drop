import XCTest
import CryptoKit
import PeerDropSecurity
@testable import PeerDrop

final class X3DHVectorTests: XCTestCase {

    struct X3DHVector: Codable {
        let name: String
        let inputs: Inputs
        let expected: Expected

        struct Inputs: Codable {
            let alice_ik_seed: String
            let bob_ik_seed: String
            let bob_spk_seed: String
            let bob_opk_seed: String
            let alice_ek_seed: String
        }
        struct Expected: Codable {
            let root_key: String
            let chain_key: String
        }
    }

    func test_all_x3dh_vectors() throws {
        let bundle = Bundle(for: type(of: self))
        // Resolve the 20 vector URLs. xcodegen bundles JSON files as individual
        // PBXFileReferences — they land in the bundle root, not in an "x3dh"
        // subdirectory. We therefore look up each file by name directly.
        let urls: [URL] = (1...20).compactMap { n -> URL? in
            let name = String(format: "vec-%03d", n)
            // Try "x3dh" subdirectory first (future-proof if bundling changes)
            return bundle.url(forResource: name, withExtension: "json", subdirectory: "x3dh")
                ?? bundle.url(forResource: name, withExtension: "json")
        }

        XCTAssertGreaterThanOrEqual(
            urls.count, 20,
            "expected ≥ 20 X3DH vectors in test bundle (got \(urls.count)) — "
            + "check that PeerDropTests/CryptoTestKit/TestVectors/x3dh/vec-*.json "
            + "are registered in PeerDrop.xcodeproj (run xcodegen generate)"
        )

        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let v: X3DHVector = try TestVectorLoader.load(from: url)
            let result = try runVector(v)
            XCTAssertEqual(
                result.rootKey.base64EncodedString(),
                v.expected.root_key,
                "rootKey mismatch in \(v.name)"
            )
            XCTAssertEqual(
                result.chainKey.base64EncodedString(),
                v.expected.chain_key,
                "chainKey mismatch in \(v.name)"
            )
        }
    }

    // MARK: - Private

    /// Reproduce the X3DH initiator side using the production
    /// `X3DH.initiatorKeyAgreement(...)` entry point, then extract
    /// raw bytes from the returned SymmetricKey values.
    private func runVector(_ v: X3DHVector) throws -> (rootKey: Data, chainKey: Data) {
        let aliceIK = DeterministicCrypto.curve25519AgreementKey(
            seed: Data(hex: v.inputs.alice_ik_seed)
        )
        let bobIK = DeterministicCrypto.curve25519AgreementKey(
            seed: Data(hex: v.inputs.bob_ik_seed)
        )
        let bobSPK = DeterministicCrypto.curve25519AgreementKey(
            seed: Data(hex: v.inputs.bob_spk_seed)
        )
        let bobOPK = DeterministicCrypto.curve25519AgreementKey(
            seed: Data(hex: v.inputs.bob_opk_seed)
        )
        let aliceEK = DeterministicCrypto.curve25519AgreementKey(
            seed: Data(hex: v.inputs.alice_ek_seed)
        )

        // Production signature (verified from X3DH.swift):
        //   X3DH.initiatorKeyAgreement(
        //     myIdentityKey:  Curve25519.KeyAgreement.PrivateKey,
        //     myEphemeralKey: Curve25519.KeyAgreement.PrivateKey,
        //     theirIdentityKey:  Curve25519.KeyAgreement.PublicKey,
        //     theirSignedPreKey: Curve25519.KeyAgreement.PublicKey,
        //     theirOneTimePreKey: Curve25519.KeyAgreement.PublicKey?  ← optional
        //   ) throws -> X3DH.KeyAgreementResult
        //
        // KeyAgreementResult has:  rootKey: SymmetricKey, chainKey: SymmetricKey
        let result = try X3DH.initiatorKeyAgreement(
            myIdentityKey: aliceIK,
            myEphemeralKey: aliceEK,
            theirIdentityKey: bobIK.publicKey,
            theirSignedPreKey: bobSPK.publicKey,
            theirOneTimePreKey: bobOPK.publicKey   // all 20 vectors include OPK
        )

        return (
            rootKey: result.rootKey.withUnsafeBytes { Data($0) },
            chainKey: result.chainKey.withUnsafeBytes { Data($0) }
        )
    }
}

// MARK: - Hex convenience

private extension Data {
    init(hex: String) {
        var data = Data()
        data.reserveCapacity(hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let byte = UInt8(hex[idx..<next], radix: 16) else { break }
            data.append(byte)
            idx = next
        }
        self = data
    }
}
