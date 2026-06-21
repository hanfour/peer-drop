import Foundation

struct CLIOptions {
    var name: String
    var restart: Bool
    var command: [String]

    static func parse(_ argv: [String], defaultShell: String) -> CLIOptions {
        var name: String? = nil
        var restart = false
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
            }
            i += 1
        }

        if command.isEmpty { command = [defaultShell] }
        let resolvedName = name ?? (Host.current().localizedName ?? "peerdrop-cli")
        return CLIOptions(name: resolvedName, restart: restart, command: command)
    }
}
