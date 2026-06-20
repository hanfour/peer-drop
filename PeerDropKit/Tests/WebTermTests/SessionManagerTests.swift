import XCTest
@testable import webterm

final class SessionManagerTests: XCTestCase {
    func test_presetDefaultShellAlwaysPresent() {
        let store = PresetStore(presets: [])
        XCTAssertTrue(store.all.contains { $0.id == "shell" })
    }
    func test_createSessionFromPresetSpawnsTmuxAndIsListed() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let preset = Preset(id: "echo\(pid)", name: "Echo", command: "echo HI; sleep 20", cwd: nil, env: nil)
        let mgr = SessionManager(presets: PresetStore(presets: [preset]))
        defer { mgr.killAll() }
        let session = try mgr.openSession(presetID: preset.id)
        XCTAssertNotNil(session)
        XCTAssertTrue(mgr.runningSessionIDs().contains("webterm-echo\(pid)"))
    }
}
