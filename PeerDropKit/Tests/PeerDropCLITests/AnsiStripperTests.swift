import XCTest
@testable import peerdrop_cli

final class AnsiStripperTests: XCTestCase {
    func test_stripsColorSequences() {
        let input = "\u{1B}[31mred\u{1B}[0m plain"
        XCTAssertEqual(AnsiStripper.strip(input), "red plain")
    }

    func test_stripsCursorAndEraseSequences() {
        let input = "line\u{1B}[2K\u{1B}[1G done"
        XCTAssertEqual(AnsiStripper.strip(input), "line done")
    }

    func test_stripsOSCTitleSequence() {
        let input = "\u{1B}]0;my title\u{07}prompt$ "
        XCTAssertEqual(AnsiStripper.strip(input), "prompt$ ")
    }

    func test_leavesPlainTextUntouched() {
        XCTAssertEqual(AnsiStripper.strip("hello world\n"), "hello world\n")
    }
}
