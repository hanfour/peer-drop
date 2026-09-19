import Foundation

/// Resolves the actual launch command + environment for the wrapped process.
///
/// For the DEFAULT shell (no explicit `-- cmd`), the chat should show command
/// *output* — not the line editor's keystroke echo or the shell prompt. Rather
/// than fragile post-hoc parsing of the shell's terminal output, we configure
/// the shell at the source: an injected `ZDOTDIR` whose `.zshrc` turns off the
/// ZLE line editor (no keystroke echo), empties the prompt, and disables
/// `PROMPT_SP` (the `%` partial-line marker). This yields a bare `hi` for
/// `echo hi` while preserving shell state (cd, env) across commands.
///
/// Only zsh — the macOS default `$SHELL` — gets this treatment. Any other shell
/// or an explicit `-- cmd` (e.g. `claude`) is launched unmodified; the universal
/// `TerminalLineNormalizer` still cleans control-char artifacts for those.
enum ShellLauncher {
    /// The clean interactive config sourced via the injected ZDOTDIR.
    static let zshrc = "unsetopt zle\nunsetopt PROMPT_SP\nPROMPT=''\nRPROMPT=''\nPROMPT2=''\n"

    /// - Parameters:
    ///   - opts: parsed CLI options.
    ///   - configDir: per-instance writable dir (the same one used for
    ///     persistence) under which the throwaway shell rc is materialised.
    /// - Returns: the command to exec and an optional environment override
    ///   (`nil` = inherit the parent environment unchanged).
    static func resolve(_ opts: CLIOptions, configDir: URL) -> (command: [String], environment: [String: String]?) {
        guard opts.isDefaultShell,
              let shell = opts.command.first,
              URL(fileURLWithPath: shell).lastPathComponent == "zsh"
        else { return (opts.command, nil) }

        let zdotdir = configDir.appendingPathComponent("shell-rc", isDirectory: true)
        try? FileManager.default.createDirectory(at: zdotdir, withIntermediateDirectories: true)
        try? zshrc.write(to: zdotdir.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)

        var env = ProcessInfo.processInfo.environment
        env["ZDOTDIR"] = zdotdir.path
        return ([shell, "-i"], env)
    }
}
