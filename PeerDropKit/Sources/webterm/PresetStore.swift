import Foundation

public struct Preset: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let command: String
    public let cwd: String?
    public let env: [String: String]?
    public init(id: String, name: String, command: String, cwd: String?, env: [String: String]?) {
        self.id = id; self.name = name; self.command = command; self.cwd = cwd; self.env = env
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
