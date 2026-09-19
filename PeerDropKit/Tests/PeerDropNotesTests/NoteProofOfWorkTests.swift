import XCTest
import PeerDropSecurity
@testable import PeerDropNotes

final class NoteProofOfWorkTests: XCTestCase {
    func testMessageFormatMatchesWorker() {
        let msg = NoteProofOfWork.message(challenge: "CHAL", recipientAccountId: "ACCT0001", envelopeBytes: Data("abc".utf8))
        XCTAssertEqual(msg, "CHAL|ACCT0001|ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
    func testSolveProducesAVerifiableNonce() async {
        let nonce = await NoteProofOfWork.solve(challenge: "c", recipientAccountId: "ACCT0001", envelopeBytes: Data([1, 2, 3]))
        XCTAssertNotNil(nonce)
        XCTAssertTrue(ProofOfWork.verify(challenge: NoteProofOfWork.message(challenge: "c", recipientAccountId: "ACCT0001", envelopeBytes: Data([1, 2, 3])), proof: nonce!, difficulty: 16))
    }
}
