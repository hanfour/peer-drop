import XCTest
@testable import PeerDropNotes

final class NoteClassificationTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func inbound(_ sender: NoteSenderState, text: String? = "hi") -> NoteRecord {
        NoteRecord(id: "n1", direction: .inbound, text: text, sentAt: t0, sender: sender,
                   recipientAccountId: nil, readAt: nil, receivedAt: t0)
    }

    private func circle(friends: Set<String> = [], diary: Set<String> = [], sentTo: Set<String> = [], hideAnonymous: Bool = false) -> CircleMembership {
        CircleMembership(friendAccountIds: friends, diaryMemberAccountIds: diary, sentSignedToAccountIds: sentTo, hideAnonymous: hideAnonymous)
    }

    // MARK: circle

    func testVerifiedBoundFriendIsCircle() {
        XCTAssertEqual(NoteClassification.classify(note: inbound(.verified(accountId: "FRIEND01", nickname: "Mochi")), circle: circle(friends: ["FRIEND01"])), .circle)
    }

    func testVerifiedDiaryMemberIsCircle() {
        XCTAssertEqual(NoteClassification.classify(note: inbound(.verified(accountId: "DIARY001", nickname: nil)), circle: circle(diary: ["DIARY001"])), .circle)
    }

    func testVerifiedSomeoneISentASignedNoteToIsCircle() {
        XCTAssertEqual(NoteClassification.classify(note: inbound(.verified(accountId: "SENT0001", nickname: nil)), circle: circle(sentTo: ["SENT0001"])), .circle)
    }

    // MARK: stranger

    func testVerifiedButUnknownSenderIsStranger() {
        XCTAssertEqual(NoteClassification.classify(note: inbound(.verified(accountId: "OTHER001", nickname: nil)), circle: circle(friends: ["FRIEND01"], diary: ["DIARY001"], sentTo: ["SENT0001"])), .stranger)
    }

    func testAnonymousIsStranger() {
        XCTAssertEqual(NoteClassification.classify(note: inbound(.anonymous), circle: circle(friends: ["FRIEND01"])), .stranger)
    }

    func testUnverifiedClaimingAFriendIdIsStrangerInEveryCircleKind() {
        let note = inbound(.unverified(accountId: "FRIEND01"))
        XCTAssertEqual(NoteClassification.classify(note: note, circle: circle(friends: ["FRIEND01"])), .stranger)
        XCTAssertEqual(NoteClassification.classify(note: note, circle: circle(diary: ["FRIEND01"])), .stranger)
        XCTAssertEqual(NoteClassification.classify(note: note, circle: circle(sentTo: ["FRIEND01"])), .stranger)
    }

    func testSpoofedDisplayNameNeverMatters() {
        // A stranger who signs with their own account but claims a friend's nickname stays a stranger,
        // and a friend stays circle whatever nickname the signed block carries.
        XCTAssertEqual(NoteClassification.classify(note: inbound(.verified(accountId: "EVIL0001", nickname: "Mochi")), circle: circle(friends: ["FRIEND01"])), .stranger)
        XCTAssertEqual(NoteClassification.classify(note: inbound(.verified(accountId: "FRIEND01", nickname: "totally-someone-else")), circle: circle(friends: ["FRIEND01"])), .circle)
    }

    func testUndecryptableNoteFromStrangerIsStranger() {
        XCTAssertEqual(NoteClassification.classify(note: inbound(.unverified(accountId: "ZZZ"), text: nil), circle: circle()), .stranger)
    }

    // MARK: hide anonymous

    func testHideAnonymousOnlyMovesAnonymousNotes() {
        let hide = circle(friends: ["FRIEND01"], hideAnonymous: true)
        XCTAssertEqual(NoteClassification.classify(note: inbound(.anonymous), circle: hide), .hiddenAnonymous)
        // signed strangers stay visible in the stranger box
        XCTAssertEqual(NoteClassification.classify(note: inbound(.verified(accountId: "OTHER001", nickname: nil)), circle: hide), .stranger)
        XCTAssertEqual(NoteClassification.classify(note: inbound(.unverified(accountId: "OTHER001")), circle: hide), .stranger)
        XCTAssertEqual(NoteClassification.classify(note: inbound(.verified(accountId: "FRIEND01", nickname: nil)), circle: hide), .circle)
    }

    func testAnonymousIsNotHiddenWhenOptionOff() {
        XCTAssertEqual(NoteClassification.classify(note: inbound(.anonymous), circle: circle(hideAnonymous: false)), .stranger)
    }

    func testOutboundNotesAreNeverStrangers() {
        let out = NoteRecord(id: "o1", direction: .outbound, text: "yo", sentAt: t0, sender: .anonymous,
                             recipientAccountId: "X", readAt: nil, receivedAt: t0)
        XCTAssertEqual(NoteClassification.classify(note: out, circle: circle(hideAnonymous: true)), .circle)
    }

    // MARK: sent-signed helper

    func testSentSignedRecipientsExcludeAnonymousAndNil() {
        let sent = [
            NoteRecord(id: "s1", direction: .outbound, text: "a", sentAt: t0, sender: .verified(accountId: "ME", nickname: nil), recipientAccountId: "SIGNED01", readAt: nil, receivedAt: t0),
            NoteRecord(id: "s2", direction: .outbound, text: "b", sentAt: t0, sender: .anonymous, recipientAccountId: "ANON0001", readAt: nil, receivedAt: t0),
            NoteRecord(id: "s3", direction: .outbound, text: "c", sentAt: t0, sender: .verified(accountId: "ME", nickname: nil), recipientAccountId: nil, readAt: nil, receivedAt: t0),
        ]
        XCTAssertEqual(CircleMembership.signedRecipients(in: sent), ["SIGNED01"])
    }
}
