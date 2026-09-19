import { killWebtermTmuxSessions } from './tmux';

/** Runs once before the whole suite: clear any stale webterm tmux sessions. */
export default async function globalSetup(): Promise<void> {
  await killWebtermTmuxSessions();
}
