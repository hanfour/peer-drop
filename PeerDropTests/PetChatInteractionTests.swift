import XCTest
@testable import PeerDrop

final class PetChatInteractionTests: XCTestCase {
    func testCatChatIsOnTop() {
        let cat = CatBehavior()
        let frames = [CGRect(x: 20, y: 100, width: 200, height: 40),
                      CGRect(x: 20, y: 160, width: 200, height: 40)]
        let result = cat.chatBehavior(messageFrames: frames, petPosition: CGPoint(x: 100, y: 300))
        XCTAssertNotNil(result)
        if case .onTop = result?.position { } else { XCTFail("Cat should use .onTop") }
    }

    func testDogChatIsBeside() {
        let dog = DogBehavior()
        let frames = [CGRect(x: 20, y: 100, width: 200, height: 40)]
        let result = dog.chatBehavior(messageFrames: frames, petPosition: CGPoint(x: 100, y: 300))
        XCTAssertNotNil(result)
        if case .beside = result?.position { } else { XCTFail("Dog should use .beside") }
    }

    func testGhostChatIsBehind() {
        let ghost = GhostBehavior()
        let frames = [CGRect(x: 20, y: 100, width: 200, height: 40)]
        let result = ghost.chatBehavior(messageFrames: frames, petPosition: CGPoint(x: 100, y: 300))
        XCTAssertNotNil(result)
        if case .behind = result?.position { } else { XCTFail("Ghost should use .behind") }
    }

    func testEmptyFramesReturnsNil() {
        let cat = CatBehavior()
        let result = cat.chatBehavior(messageFrames: [], petPosition: CGPoint(x: 100, y: 300))
        XCTAssertNil(result)
    }

    func testSlimeChatIsDripping() {
        let slime = SlimeBehavior()
        let frames = [CGRect(x: 20, y: 100, width: 200, height: 40)]
        let result = slime.chatBehavior(messageFrames: frames, petPosition: CGPoint(x: 100, y: 300))
        XCTAssertNotNil(result)
        if case .dripping = result?.position { } else { XCTFail("Slime should use .dripping") }
    }

    func testOctopusChatIsWrapped() {
        let octopus = OctopusBehavior()
        let frames = [CGRect(x: 20, y: 100, width: 200, height: 40)]
        let result = octopus.chatBehavior(messageFrames: frames, petPosition: CGPoint(x: 100, y: 300))
        XCTAssertNotNil(result)
        if case .wrappedAround = result?.position { } else { XCTFail("Octopus should use .wrappedAround") }
    }

    func testDragonChatIsCoiled() {
        let dragon = DragonBehavior()
        let frames = [CGRect(x: 20, y: 100, width: 200, height: 40)]
        let result = dragon.chatBehavior(messageFrames: frames, petPosition: CGPoint(x: 100, y: 300))
        XCTAssertNotNil(result)
        if case .coiled = result?.position { } else { XCTFail("Dragon should use .coiled") }
    }
}
