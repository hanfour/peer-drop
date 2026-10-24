import XCTest
import CryptoKit
import PeerDropCore
import PeerDropSecurity
@testable import PeerDrop

final class HomeCategoriesLogicTests: XCTestCase {
    private func rec(_ id: String, _ name: String, peerIdentityId: String? = nil) -> DeviceRecord {
        var r = DeviceRecord(id: id, displayName: name, sourceType: "bonjour", lastConnected: Date(), connectionCount: 1)
        r.peerIdentityId = peerIdentityId
        return r
    }

    private func cat(_ id: String, _ name: String, _ members: [String] = [], order: Int = 0) -> FriendCategory {
        FriendCategory(id: id, name: name, order: order, friendIDs: members)
    }

    private func sections(_ records: [DeviceRecord], online: Set<String> = [], query: String = "",
                          categories: [FriendCategory]) -> HomeListLogic.HomeSections {
        let assignment = HomeListLogic.categoryIDs(for: records, categories: categories, aliases: { [$0.id] })
        return HomeListLogic.homeSections(records: records,
                                          presence: { online.contains($0.id) ? .online : .offline },
                                          query: query,
                                          categories: categories,
                                          categoryID: { assignment[$0.id] })
    }

    func testCategorizedFriendsLeaveFriendsSection() {
        let all = [rec("a", "Amy"), rec("b", "Bob")]
        let s = sections(all, categories: [cat("fam", "Family", ["a"])])
        XCTAssertEqual(s.friends.map(\.id), ["b"])
        XCTAssertEqual(s.categories.map(\.category.id), ["fam"])
        XCTAssertEqual(s.categories.first?.members.map(\.id), ["a"])
    }

    func testConnectedCategorizedFriendStillShownInConnected() {
        let all = [rec("a", "Amy"), rec("b", "Bob")]
        let s = sections(all, online: ["a"], categories: [cat("fam", "Family", ["a"])])
        XCTAssertEqual(s.connected.map(\.id), ["a"])
        XCTAssertEqual(s.friends.map(\.id), ["b"])
        XCTAssertEqual(s.categories.first?.members.map(\.id), ["a"])
    }

    func testCategoryMemberCountIncludesConnected() {
        let all = [rec("a", "Amy"), rec("c", "Cat"), rec("b", "Bob")]
        let s = sections(all, online: ["a"], categories: [cat("fam", "Family", ["c", "a"])])
        XCTAssertEqual(s.categories.first?.count, 2)
        // members sorted by name
        XCTAssertEqual(s.categories.first?.members.map(\.displayName), ["Amy", "Cat"])
    }

    func testSearchFiltersCategoriesByNameAndMembers() {
        let all = [rec("a", "Amy"), rec("b", "Bob")]
        let cats = [cat("fam", "Family", ["a"], order: 0), cat("work", "Work", ["b"], order: 1), cat("gym", "Gym", [], order: 2)]
        XCTAssertEqual(sections(all, query: "fam", categories: cats).categories.map(\.category.id), ["fam"])
        XCTAssertEqual(sections(all, query: " BOB ", categories: cats).categories.map(\.category.id), ["work"])
        XCTAssertTrue(sections(all, query: "zzz", categories: cats).categories.isEmpty)
        // Count is the whole category, not just the matching members.
        let all3 = all + [rec("c", "Cat")]
        let cats3 = [cat("fam", "Family", ["a", "c"])]
        XCTAssertEqual(sections(all3, query: "amy", categories: cats3).categories.first?.count, 2)
    }

    func testSearchListsCategorizedFriendWithItsCategoryName() {
        let all = [rec("a", "Amy"), rec("b", "Amber"), rec("c", "Cat")]
        let s = sections(all, query: "am", categories: [cat("fam", "Family", ["a"])])
        XCTAssertEqual(s.friends.map(\.id), ["b", "a"])          // sorted by name: Amber, Amy
        XCTAssertEqual(s.friendCategoryNames, ["a": "Family"])
        // A connected categorized match stays in 已連線 only.
        let online = sections(all, online: ["a"], query: "am", categories: [cat("fam", "Family", ["a"])])
        XCTAssertEqual(online.friends.map(\.id), ["b"])
        XCTAssertEqual(online.connected.map(\.id), ["a"])
        XCTAssertTrue(online.friendCategoryNames.isEmpty)
    }

    func testEmptyQueryKeepsCategorizedFriendsOut() {
        let all = [rec("a", "Amy"), rec("b", "Bob")]
        for q in ["", "   "] {
            let s = sections(all, query: q, categories: [cat("fam", "Family", ["a"])])
            XCTAssertEqual(s.friends.map(\.id), ["b"])
            XCTAssertTrue(s.friendCategoryNames.isEmpty)
        }
    }

    func testInlineNameSubmitDecision() {
        XCTAssertEqual(InlineNameSubmit.decide(text: "  Family "), .create("Family"))
        XCTAssertEqual(InlineNameSubmit.decide(text: ""), .cancel)
        XCTAssertEqual(InlineNameSubmit.decide(text: "   "), .keepEditing)
        XCTAssertEqual(InlineNameSubmit.decide(text: String(repeating: "x", count: 21)), .keepEditing)
        XCTAssertEqual(InlineNameSubmit.decide(text: String(repeating: "x", count: 20)), .create(String(repeating: "x", count: 20)))
    }

    func testEmptyCategoriesListedInStoreOrderWithoutQuery() {
        let cats = [cat("w", "Work", order: 0), cat("f", "Family", order: 1)]
        let s = sections([], categories: cats)
        XCTAssertEqual(s.categories.map(\.category.id), ["w", "f"])
        XCTAssertEqual(s.categories.map(\.count), [0, 0])
    }

    func testMembersIgnoreIDsWithoutRecord() {
        let s = sections([rec("a", "Amy")], categories: [cat("fam", "Family", ["a", "gone"])])
        XCTAssertEqual(s.categories.first?.count, 1)
    }

    func testSecondRecordOfSamePersonFollowsCategory() {
        // "b" is a second record of the same person as "a" (shared identity id).
        let all = [rec("a", "Amy", peerIdentityId: "pid"), rec("b", "Amy (Mac)", peerIdentityId: "pid"), rec("c", "Cat")]
        let cats = [cat("fam", "Family", ["a"])]
        let aliases: (DeviceRecord) -> [String] = { r in
            all.filter { $0.peerIdentityId != nil && $0.peerIdentityId == r.peerIdentityId }.map(\.id) + [r.id]
        }
        let assignment = HomeListLogic.categoryIDs(for: all, categories: cats, aliases: aliases)
        XCTAssertEqual(assignment["a"], "fam")
        XCTAssertEqual(assignment["b"], "fam")
        XCTAssertNil(assignment["c"])
        let s = HomeListLogic.homeSections(records: all, presence: { _ in .offline }, query: "",
                                           categories: cats, categoryID: { assignment[$0.id] })
        XCTAssertEqual(s.friends.map(\.id), ["c"])
        XCTAssertEqual(Set(s.categories.first?.members.map(\.id) ?? []), ["a", "b"])
    }

    func testCategoryNameValidity() {
        XCTAssertTrue(HomeListLogic.isValidCategoryName("  家人 "))
        XCTAssertFalse(HomeListLogic.isValidCategoryName("   "))
        XCTAssertFalse(HomeListLogic.isValidCategoryName(String(repeating: "a", count: 21)))
        XCTAssertTrue(HomeListLogic.isValidCategoryName(String(repeating: "a", count: 20)))
    }

    // MARK: - Moving a person (all of their records) between categories

    @MainActor
    func testMovePersonClearsTheirOtherRecordFromOldCategory() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hcl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let suite = "hcl-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = FriendCategoryStore(directory: dir, encryptor: ChatDataEncryptor(testKey: SymmetricKey(size: .bits256)),
                                        migrationDefaults: defaults)
        let fam = store.create(name: "Family")!
        let work = store.create(name: "Work")!
        store.assign(friendID: "a", to: fam.id)        // the person's first record

        store.move(person: ["a", "b"], record: "b", to: work.id)   // moved via their second record
        XCTAssertEqual(store.categories.first { $0.id == fam.id }?.friendIDs, [])
        XCTAssertEqual(store.categories.first { $0.id == work.id }?.friendIDs, ["b"])
        XCTAssertEqual(store.category(containingAnyOf: ["a", "b"])?.id, work.id)

        store.move(person: ["a", "b"], record: "a", to: nil)
        XCTAssertNil(store.category(containingAnyOf: ["a", "b"]))
    }
}
