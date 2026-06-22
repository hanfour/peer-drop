import XCTest
@testable import peerdrop_cli

final class CLIOptionsTests: XCTestCase {
    func test_defaultsToShellWhenNoCommand() {
        let o = CLIOptions.parse(["peerdrop-cli"], defaultShell: "/bin/zsh")
        XCTAssertEqual(o.command, ["/bin/zsh"])
        XCTAssertTrue(o.isDefaultShell)
        XCTAssertFalse(o.restart)
        XCTAssertNotNil(o.name)
    }

    func test_parsesNameAndCommandAfterDashDash() {
        let o = CLIOptions.parse(
            ["peerdrop-cli", "--name", "claude@proj", "--restart", "--", "claude", "--foo"],
            defaultShell: "/bin/zsh"
        )
        XCTAssertEqual(o.name, "claude@proj")
        XCTAssertTrue(o.restart)
        XCTAssertEqual(o.command, ["claude", "--foo"])
        XCTAssertFalse(o.isDefaultShell)
    }
}
