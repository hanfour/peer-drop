import XCTest
import PeerDropNotes
@testable import PeerDrop

final class InboxDeepLinkTests: XCTestCase {
    private let map = ["BOUND123": "rec-1"]
    private func dest(_ s: NoteSenderState?) -> InboxDeepLink.Destination {
        InboxDeepLink.destination(sender: s, recordIDForAccount: { map[$0] })
    }

    func testVerifiedBoundSenderOpensThread() {
        XCTAssertEqual(dest(.verified(accountId: "BOUND123", nickname: "A")), .thread(recordID: "rec-1"))
    }

    func testUnboundVerifiedSenderGoesToInbox() {
        XCTAssertEqual(dest(.verified(accountId: "OTHER", nickname: nil)), .inbox)
    }

    func testUnverifiedOrAnonymousSenderGoesToInboxEvenIfIdIsBound() {
        XCTAssertEqual(dest(.unverified(accountId: "BOUND123")), .inbox)
        XCTAssertEqual(dest(.anonymous), .inbox)
    }

    func testUnknownNoteGoesToInbox() {
        XCTAssertEqual(dest(nil), .inbox)
    }

    func testThreadActionPushWhenNothingShowing() {
        XCTAssertEqual(InboxDeepLink.threadAction(inboxShowing: false, chatShowing: false, sameThreadShowing: false), .push)
    }

    func testThreadActionNoneWhenSameThreadAlreadyOpen() {
        XCTAssertEqual(InboxDeepLink.threadAction(inboxShowing: false, chatShowing: true, sameThreadShowing: true), .none)
    }

    func testThreadActionDismissesInboxOrOtherChatFirst() {
        XCTAssertEqual(InboxDeepLink.threadAction(inboxShowing: true, chatShowing: false, sameThreadShowing: false), .dismissThenPush)
        XCTAssertEqual(InboxDeepLink.threadAction(inboxShowing: false, chatShowing: true, sameThreadShowing: false), .dismissThenPush)
    }

    func testInboxActionsUnchangedForInboxDestination() {
        XCTAssertEqual(InboxDeepLink.action(inboxShowing: true, chatShowing: false), .none)
        XCTAssertEqual(InboxDeepLink.action(inboxShowing: false, chatShowing: true), .dismissChatThenPush)
        XCTAssertEqual(InboxDeepLink.action(inboxShowing: false, chatShowing: false), .push)
    }

    func testThreadRequestConsumedOnce() {
        XCTAssertTrue(InboxDeepLink.shouldConsumeThread(pending: ThreadRequest(recordID: "rec-1", noteID: "n1")))
        XCTAssertFalse(InboxDeepLink.shouldConsumeThread(pending: nil))
    }
}
