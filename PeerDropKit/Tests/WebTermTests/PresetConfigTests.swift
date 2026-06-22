import XCTest
@testable import webterm

final class PresetConfigTests: XCTestCase {

    // MARK: - Decode tests

    /// Decode a JSON array with one preset that has `autostart: true`.
    func test_decode_withAutostart_true() throws {
        let json = """
        [
          {
            "id": "claude",
            "name": "Claude Code",
            "command": "claude",
            "cwd": "/Users/you/Projects/foo",
            "env": { "FOO": "bar" },
            "autostart": true
          }
        ]
        """
        let data = Data(json.utf8)
        let presets = try JSONDecoder().decode([Preset].self, from: data)
        XCTAssertEqual(presets.count, 1)
        let p = presets[0]
        XCTAssertEqual(p.id, "claude")
        XCTAssertEqual(p.name, "Claude Code")
        XCTAssertEqual(p.command, "claude")
        XCTAssertEqual(p.cwd, "/Users/you/Projects/foo")
        XCTAssertEqual(p.env, ["FOO": "bar"])
        XCTAssertTrue(p.autostart, "autostart should be true when the JSON field is true")
    }

    /// Decode a JSON preset WITHOUT the `autostart` key — must default to false (back-compat).
    func test_decode_withoutAutostart_defaultsFalse() throws {
        let json = """
        [
          {
            "id": "shell",
            "name": "Shell",
            "command": "/bin/zsh"
          }
        ]
        """
        let data = Data(json.utf8)
        let presets = try JSONDecoder().decode([Preset].self, from: data)
        XCTAssertEqual(presets.count, 1)
        let p = presets[0]
        XCTAssertEqual(p.id, "shell")
        XCTAssertFalse(p.autostart, "autostart must default to false when the JSON field is absent")
        XCTAssertNil(p.cwd)
        XCTAssertNil(p.env)
    }

    /// Decode a preset with `autostart: false` explicitly.
    func test_decode_withAutostart_false() throws {
        let json = """
        [{ "id": "x", "name": "X", "command": "echo x", "autostart": false }]
        """
        let presets = try JSONDecoder().decode([Preset].self, from: Data(json.utf8))
        XCTAssertFalse(presets[0].autostart)
    }

    /// Preset is Codable round-trip: encode then decode preserves `autostart`.
    func test_encodeDecode_roundTrip() throws {
        let original = Preset(id: "rt", name: "RoundTrip", command: "echo RT", cwd: nil, env: nil, autostart: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Preset.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertTrue(decoded.autostart)
    }

    // MARK: - Autostart integration test

    /// `buildApplication` with `autostartPresets: true` creates a tmux session for each
    /// preset that has `autostart == true`, but NOT for presets with `autostart == false`.
    ///
    /// Requires tmux at /opt/homebrew/bin/tmux or visible on PATH.
    func test_autostartPresets_createsSessionForAutostartOnly() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let autoID = "auto\(pid)"
        let noAutoID = "noauto\(pid)"
        let autoTmuxID = TmuxControl.prefix + autoID
        let noAutoTmuxID = TmuxControl.prefix + noAutoID

        defer {
            _ = try? TmuxControl.kill(autoTmuxID)
            _ = try? TmuxControl.kill(noAutoTmuxID)
        }

        let presets = [
            Preset(id: autoID, name: "Auto", command: "echo HI; sleep 20", cwd: nil, env: nil, autostart: true),
            Preset(id: noAutoID, name: "NoAuto", command: "echo BYE; sleep 20", cwd: nil, env: nil, autostart: false),
        ]
        let cfg = WebTermConfig(
            port: 0,
            expectedHost: "localhost",
            auth: .password(hash: PasswordHash.make("x")),
            sessionSecret: Data((0..<32).map { _ in UInt8.random(in: 0...255) }),
            presets: presets
        )

        // Pre-condition: neither tmux session should exist yet
        XCTAssertFalse(TmuxControl.exists(autoTmuxID), "tmux session '\(autoTmuxID)' must not exist before buildApplication")
        XCTAssertFalse(TmuxControl.exists(noAutoTmuxID), "tmux session '\(noAutoTmuxID)' must not exist before buildApplication")

        _ = try buildApplication(cfg, cfVerifier: nil, autostartPresets: true)

        XCTAssertTrue(TmuxControl.exists(autoTmuxID),
                      "tmux session '\(autoTmuxID)' must be created for a preset with autostart == true")
        XCTAssertFalse(TmuxControl.exists(noAutoTmuxID),
                       "tmux session '\(noAutoTmuxID)' must NOT be created for a preset with autostart == false")
    }

    /// Calling `buildApplication` WITHOUT `autostartPresets: true` (default false) must not
    /// spawn any tmux sessions — preserving backward-compat for existing tests.
    func test_buildApplication_defaultNoAutostart_doesNotSpawnSessions() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let autoID = "autoskip\(pid)"
        let tmuxID = TmuxControl.prefix + autoID
        defer { _ = try? TmuxControl.kill(tmuxID) }

        let presets = [
            Preset(id: autoID, name: "AutoSkip", command: "echo HI; sleep 20", cwd: nil, env: nil, autostart: true),
        ]
        let cfg = WebTermConfig(
            port: 0,
            expectedHost: "localhost",
            auth: .password(hash: PasswordHash.make("y")),
            sessionSecret: Data((0..<32).map { _ in UInt8.random(in: 0...255) }),
            presets: presets
        )

        _ = try buildApplication(cfg)  // no autostartPresets argument → default false

        XCTAssertFalse(TmuxControl.exists(tmuxID),
                       "buildApplication with default autostartPresets (false) must not spawn any tmux sessions")
    }
}
