import XCTest
@testable import peerdrop_cli

final class ShellLauncherTests: XCTestCase {
    private func tmpDir() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("shelltest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func test_defaultZsh_getsDashIAndCleanZdotdir() throws {
        let opts = CLIOptions.parse(["peerdrop-cli"], defaultShell: "/bin/zsh")
        let dir = tmpDir()
        let (command, env) = ShellLauncher.resolve(opts, configDir: dir)

        XCTAssertEqual(command, ["/bin/zsh", "-i"])
        let zdotdir = try XCTUnwrap(env?["ZDOTDIR"])
        let rc = try String(contentsOfFile: zdotdir + "/.zshrc", encoding: .utf8)
        XCTAssertTrue(rc.contains("unsetopt zle"))
        XCTAssertTrue(rc.contains("PROMPT=''"))
    }

    func test_explicitCommand_launchedUnmodified_noEnvOverride() {
        let opts = CLIOptions.parse(["peerdrop-cli", "--", "claude", "--foo"], defaultShell: "/bin/zsh")
        let (command, env) = ShellLauncher.resolve(opts, configDir: tmpDir())

        XCTAssertEqual(command, ["claude", "--foo"])
        XCTAssertNil(env)
    }

    func test_nonZshDefaultShell_notSpeciallyConfigured() {
        let opts = CLIOptions.parse(["peerdrop-cli"], defaultShell: "/bin/bash")
        let (command, env) = ShellLauncher.resolve(opts, configDir: tmpDir())

        XCTAssertEqual(command, ["/bin/bash"])
        XCTAssertNil(env)
    }
}
