import XCTest
@testable import PeerDropCore

@MainActor
final class GroupPushRoutingTests: XCTestCase {
    private let groupId = "01ARZ3NDEKTSV4RRFFQ69G5FAV"

    func testRoutesGroupMessagePush() async {
        let spy = GroupPushSpy()
        let manager = PushNotificationManager(groupPushHandler: spy)

        await manager.handleGroupPush(["type": "groupMessage", "groupId": groupId])

        XCTAssertEqual(spy.received.count, 1)
        XCTAssertEqual(spy.received.first?.kind, "groupMessage")
        XCTAssertEqual(spy.received.first?.groupId, groupId)
    }

    func testRoutesGroupKeyRequestPush() async {
        let spy = GroupPushSpy()
        let manager = PushNotificationManager(groupPushHandler: spy)

        await manager.handleGroupPush(["type": "groupKeyRequest", "groupId": groupId])

        XCTAssertEqual(spy.received.count, 1)
        XCTAssertEqual(spy.received.first?.kind, "groupKeyRequest")
        XCTAssertEqual(spy.received.first?.groupId, groupId)
    }

    func testIgnoresMissingGroupId() async {
        let spy = GroupPushSpy()
        let manager = PushNotificationManager(groupPushHandler: spy)

        await manager.handleGroupPush(["type": "groupMessage"])

        XCTAssertTrue(spy.received.isEmpty)
    }

    func testIgnoresUnknownType() async {
        let spy = GroupPushSpy()
        let manager = PushNotificationManager(groupPushHandler: spy)

        await manager.handleGroupPush(["type": "groupUpdated", "groupId": groupId])

        XCTAssertTrue(spy.received.isEmpty)
    }

    func testIgnoresMalformedGroupId() async {
        let spy = GroupPushSpy()
        let manager = PushNotificationManager(groupPushHandler: spy)

        await manager.handleGroupPush(["type": "groupMessage", "groupId": "01ARZ3NDEKTSV4RRFFQ69G5FAU"])

        XCTAssertTrue(spy.received.isEmpty)
    }
}

@MainActor
private final class GroupPushSpy: GroupPushHandling {
    struct ReceivedPush {
        let kind: String
        let groupId: String
    }

    private(set) var received: [ReceivedPush] = []

    func handlePush(kind: String, groupId: String) async {
        received.append(ReceivedPush(kind: kind, groupId: groupId))
    }
}
