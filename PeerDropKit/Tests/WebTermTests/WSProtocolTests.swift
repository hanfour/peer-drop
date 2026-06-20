import XCTest
@testable import webterm

final class WSProtocolTests: XCTestCase {
    func test_dataFrameRoundTrip() {
        let payload = Data("abc".utf8)
        let frame = WSFrame.data(payload).encoded()
        XCTAssertEqual(WSFrame.decode(frame), .data(payload))
    }
    func test_resizeFrameRoundTrip() {
        let frame = WSFrame.resize(cols: 100, rows: 24).encoded()
        XCTAssertEqual(WSFrame.decode(frame), .resize(cols: 100, rows: 24))
    }
    func test_pingFrame() {
        XCTAssertEqual(WSFrame.decode(WSFrame.ping.encoded()), .ping)
    }
    func test_emptyOrUnknownDecodesNil() {
        XCTAssertNil(WSFrame.decode(Data()))
        XCTAssertNil(WSFrame.decode(Data([0x09])))
    }
}
