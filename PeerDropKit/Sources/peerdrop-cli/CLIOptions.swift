import Foundation

struct CLIOptions {
    var name: String
    var restart: Bool
    var command: [String]
    /// True when no explicit `-- cmd` was given and `command` fell back to the
    /// login shell. The clean-shell config (see `ShellLauncher`) is applied only
    /// in this case, so an explicit program (e.g. `claude`) is launched as-is.
    var isDefaultShell: Bool
    /// Headless agent mode: each chat message runs the command via `-p` and the
    /// reply is one plain-text bubble (see `AgentBridge`).
    var isAgent: Bool
    /// Escalates the agent's permission mode from `plan` to `bypassPermissions`
    /// (executes edits/commands). Implies `isAgent`. NOTE: even the default
    /// `plan` still runs read-only tools, so a paired peer can have the agent
    /// read & return host file contents — `bypassPermissions` additionally lets
    /// it modify files and run commands.
    var agentYolo: Bool

    static func parse(_ argv: [String], defaultShell: String) -> CLIOptions {
        var name: String? = nil
        var restart = false
        var isAgent = false
        var agentYolo = false
        var command: [String] = []

        var i = 1
        while i < argv.count {
            let arg = argv[i]
            if arg == "--" {
                command = Array(argv[(i + 1)...])
                break
            } else if arg == "--name", i + 1 < argv.count {
                name = argv[i + 1]; i += 2; continue
            } else if arg == "--restart" {
                restart = true; i += 1; continue
            } else if arg == "--agent" {
                isAgent = true; i += 1; continue
            } else if arg == "--agent-yolo" {
                isAgent = true; agentYolo = true; i += 1; continue
            }
            i += 1
        }

        // No explicit `-- cmd`: agent mode defaults to `claude`, otherwise the
        // login shell.
        let defaulted = command.isEmpty
        if defaulted { command = isAgent ? ["claude"] : [defaultShell] }
        // The clean-shell config applies only to a defaulted, non-agent shell.
        let isDefaultShell = defaulted && !isAgent
        let resolvedName = name ?? (Host.current().localizedName ?? "peerdrop-cli")
        return CLIOptions(name: resolvedName, restart: restart, command: command,
                          isDefaultShell: isDefaultShell, isAgent: isAgent, agentYolo: agentYolo)
    }
}
