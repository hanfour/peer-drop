import XCTest
@testable import PeerDropSecurity

/// A blank stored display name (e.g. the Mac settings field cleared, which
/// `@AppStorage` persists as "") used to win over the device-name fallback,
/// because `??` only falls through on nil. Peers then received an empty name
/// in the HELLO and showed a blank row / "Other person" in chat.
final class PeerIdentityLocalNameTests: XCTestCase {
    func test_nilStoredName_usesFallback() {
        XCTAssertEqual(PeerIdentity.resolveLocalName(stored: nil, fallback: "Mac mini"), "Mac mini")
    }

    func test_emptyStoredName_usesFallback() {
        XCTAssertEqual(PeerIdentity.resolveLocalName(stored: "", fallback: "Mac mini"), "Mac mini")
    }

    func test_whitespaceOnlyStoredName_usesFallback() {
        XCTAssertEqual(PeerIdentity.resolveLocalName(stored: "  \n\t ", fallback: "Mac mini"), "Mac mini")
        XCTAssertEqual(PeerIdentity.resolveLocalName(stored: "\u{3000}", fallback: "Mac mini"), "Mac mini")
    }

    func test_realStoredName_winsAndIsTrimmed() {
        XCTAssertEqual(PeerIdentity.resolveLocalName(stored: "  小安的 Mac ", fallback: "Mac mini"), "小安的 Mac")
    }
}
