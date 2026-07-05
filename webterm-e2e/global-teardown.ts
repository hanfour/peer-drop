import { killWebtermTmuxSessions } from './tmux';

/** Runs once after the whole suite: leave no orphaned webterm tmux sessions behind. */
export default async function globalTeardown(): Promise<void> {
  await killWebtermTmuxSessions();
}
