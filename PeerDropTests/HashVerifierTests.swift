import XCTest
@testable import PeerDrop

final class HashVerifierTests: XCTestCase {

    func testSHA256StaticHash() {
        let data = "Hello, World!".data(using: .utf8)!
        let hash = HashVerifier.sha256(data)
        // Known SHA-256 of "Hello, World!"
        XCTAssertEqual(hash, "dffd6021bb2bd5b0af676290809ec3a53191dd81c7f70a4b28688a362182986f")
    }

    func testIncrementalHashMatchesStatic() {
        let data = "Hello, World!".data(using: .utf8)!

        let verifier = HashVerifier()
        verifier.update(with: data)
        let incrementalHash = verifier.finalize()

        let staticHash = HashVerifier.sha256(data)
        XCTAssertEqual(incrementalHash, staticHash)
    }

    func testIncrementalHashWithMultipleChunks() {
        let fullData = "Hello, World!".data(using: .utf8)!
        let chunks = fullData.chunks(ofSize: 4)

        let verifier = HashVerifier()
        for chunk in chunks {
            verifier.update(with: chunk)
        }
        let hash = verifier.finalize()

        let expected = HashVerifier.sha256(fullData)
        XCTAssertEqual(hash, expected)
    }

    func testVerifyMatching() {
        let data = "test".data(using: .utf8)!
        let hash = HashVerifier.sha256(data)

        let verifier = HashVerifier()
        verifier.update(with: data)
        XCTAssertTrue(verifier.verify(expected: hash))
    }

    func testVerifyMismatch() {
        let data = "test".data(using: .utf8)!

        let verifier = HashVerifier()
        verifier.update(with: data)
        XCTAssertFalse(verifier.verify(expected: "0000000000000000000000000000000000000000000000000000000000000000"))
    }

    func testEmptyData() {
        let data = Data()
        let hash = HashVerifier.sha256(data)
        // SHA-256 of empty string
        XCTAssertEqual(hash, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }
}
