import Foundation

public struct Preset: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let command: String
    public let cwd: String?
    public let env: [String: String]?
    public let autostart: Bool

    public init(id: String, name: String, command: String, cwd: String?, env: [String: String]?, autostart: Bool = false) {
        self.id = id; self.name = name; self.command = command; self.cwd = cwd; self.env = env; self.autostart = autostart
    }

    private enum CodingKeys: String, CodingKey { case id, name, command, cwd, env, autostart }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        command = try c.decode(String.self, forKey: .command)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        env = try c.decodeIfPresent([String: String].self, forKey: .env)
        autostart = try c.decodeIfPresent(Bool.self, forKey: .autostart) ?? false
    }
}

public final class PresetStore {
    public let all: [Preset]
    public init(presets: [Preset]) {
        let shell = Preset(id: "shell", name: "Shell",
                           command: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
                           cwd: nil, env: nil)
        var seen = Set(["shell"]); var out = [shell]
        for p in presets where !seen.contains(p.id) { out.append(p); seen.insert(p.id) }
        self.all = out
    }
    public func preset(_ id: String) -> Preset? { all.first { $0.id == id } }
}
