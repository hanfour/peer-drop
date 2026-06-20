import Foundation

public final class SessionManager {
    private let presets: PresetStore
    private var sessions: [String: TerminalSession] = [:]
    private let lock = NSLock()
    public init(presets: PresetStore) { self.presets = presets }

    /// Open (or reattach) the tmux session for a preset; returns a TerminalSession.
    public func openSession(presetID: String) throws -> TerminalSession {
        guard let p = presets.preset(presetID) else { throw WebTermError.unknownPreset(presetID) }
        let tmuxID = TmuxControl.prefix + p.id
        try TmuxControl.createIfNeeded(id: tmuxID, command: p.command, cwd: p.cwd)
        lock.lock(); defer { lock.unlock() }
        if let existing = sessions[tmuxID] { return existing }
        let s = TerminalSession(id: tmuxID); sessions[tmuxID] = s; return s
    }

    public var allPresets: [Preset] { presets.all }

    public func runningSessionIDs() -> [String] {
        presets.all.map { TmuxControl.prefix + $0.id }.filter { TmuxControl.exists($0) }
    }
    public func killAll() {
        for id in runningSessionIDs() { _ = try? TmuxControl.kill(id) }
        lock.lock(); sessions.removeAll(); lock.unlock()
    }
}

public enum WebTermError: Error, Equatable { case unknownPreset(String) }
