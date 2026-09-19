import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const pexec = promisify(execFile);

/**
 * Kill any tmux sessions created by webterm (prefix "webterm-", see TmuxControl.prefix).
 *
 * webterm caches a TerminalSession per tmux session id for the lifetime of the server
 * process, and a tmux session outlives the webterm process (that is the whole point of
 * tmux-backed persistence). Left over from a previous `playwright test` run, a stale
 * `webterm-shell` session would replay old scrollback into a fresh run and make the
 * smoke assertions non-deterministic. Clearing it before (globalSetup) and after
 * (globalTeardown) keeps each run hermetic. Best-effort: a missing tmux binary or an
 * absent tmux server is a no-op, not a failure.
 */
export async function killWebtermTmuxSessions(): Promise<void> {
  try {
    const { stdout } = await pexec('tmux', ['list-sessions', '-F', '#{session_name}']);
    const names = stdout
      .split('\n')
      .map((s) => s.trim())
      .filter((n) => n.startsWith('webterm-'));
    for (const name of names) {
      await pexec('tmux', ['kill-session', '-t', name]).catch(() => {});
    }
  } catch {
    // No tmux server running, or tmux not installed — nothing to clean.
  }
}
