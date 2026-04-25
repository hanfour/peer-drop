import type { Traits } from '../traits/types';
import { dominantTrait } from '../traits/types';

export type GreetingAction = 'walking' | 'scared' | 'tapReact' | 'idle';

export type GreetingBeat = {
  action: GreetingAction;
  durationMs: number;
  /** Percentage-point delta to nudge the local pet horizontally. */
  xOffset?: number;
};

/**
 * Pick a one-shot greeting beat for the local pet when a peer arrives.
 * Each dominant trait yields a distinct flavor:
 *   - curious:     trots toward the peer (walking, +xOffset)
 *   - timid:       startles and shrinks back (scared, -xOffset)
 *   - mischievous: a quick poke (tapReact, no offset)
 *   - independent: a brief glance — effectively idle
 */
export function selectGreeting(traits: Traits): GreetingBeat {
  switch (dominantTrait(traits)) {
    case 'curious':
      return { action: 'walking', durationMs: 1500, xOffset: 15 };
    case 'timid':
      return { action: 'scared', durationMs: 1200, xOffset: -10 };
    case 'mischievous':
      return { action: 'tapReact', durationMs: 800 };
    case 'independent':
      return { action: 'idle', durationMs: 600 };
  }
}
