import type { Traits, TraitName } from '../traits/types';
import type { DialogueContext, DialogueLine } from './types';
import { linePool } from './pool';

/**
 * Pick a dialogue line for the given context, biased by the pet's traits.
 * Each candidate gets a score of `1 + sum((trait/100) * weight)`; we then
 * sample one with probability proportional to its score.
 *
 * The +1 baseline ensures lines whose tagged traits are at 0 still have a
 * non-zero chance, so we never get a degenerate empty pool.
 */
export function selectLine(traits: Traits, ctx: DialogueContext): DialogueLine | null {
  const candidates = linePool.filter((l) => l.context === ctx);
  if (candidates.length === 0) return null;
  const weights = candidates.map((l) => {
    let w = 1;
    for (const [trait, weight] of Object.entries(l.traitWeights)) {
      if (weight === undefined) continue;
      w += (traits[trait as TraitName] / 100) * weight;
    }
    return w;
  });
  const total = weights.reduce((a, b) => a + b, 0);
  let r = Math.random() * total;
  for (let i = 0; i < candidates.length; i++) {
    r -= weights[i];
    if (r <= 0) return candidates[i];
  }
  return candidates[candidates.length - 1];
}
