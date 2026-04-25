import type { DialogueLine } from './types';

/**
 * Trait-weighted dialogue pool. Each line carries weights against the four
 * trait axes; the selector adds `(trait/100) * weight` per match plus a
 * baseline of 1, so untagged traits don't get zeroed out.
 *
 * v0 corpus is intentionally short and English-only — multilingual lines
 * are out of scope until the design is approved.
 */
export const linePool: DialogueLine[] = [
  // idle
  { text: '...', context: 'idle', traitWeights: { timid: 80, independent: 30 } },
  { text: 'Hmm.', context: 'idle', traitWeights: { independent: 70 } },
  { text: "What's that?", context: 'idle', traitWeights: { curious: 90 } },
  { text: 'Oooh!', context: 'idle', traitWeights: { curious: 70, mischievous: 30 } },
  { text: 'meh.', context: 'idle', traitWeights: { independent: 80, mischievous: 30 } },
  { text: 'Hey hey hey.', context: 'idle', traitWeights: { mischievous: 90 } },
  { text: 'zZz', context: 'idle', traitWeights: { independent: 60, timid: 40 } },

  // greeting
  { text: 'Hi!', context: 'greeting', traitWeights: { curious: 80 } },
  { text: 'oh!', context: 'greeting', traitWeights: { timid: 70, curious: 40 } },
  { text: '...hey.', context: 'greeting', traitWeights: { independent: 80 } },
  { text: 'whoa whoa whoa', context: 'greeting', traitWeights: { mischievous: 90, curious: 40 } },
  { text: 'who are you', context: 'greeting', traitWeights: { timid: 70, curious: 60 } },
  { text: 'sniff sniff', context: 'greeting', traitWeights: { curious: 100 } },

  // tap
  { text: 'heh.', context: 'tap', traitWeights: { mischievous: 90 } },
  { text: '!', context: 'tap', traitWeights: { timid: 70, curious: 40 } },
  { text: '~', context: 'tap', traitWeights: { independent: 60 } },
  { text: '<3', context: 'tap', traitWeights: { curious: 50, timid: 40 } },
  { text: 'haha what', context: 'tap', traitWeights: { mischievous: 80 } },

  // transferSuccess
  { text: 'Yay!!', context: 'transferSuccess', traitWeights: { curious: 60, mischievous: 70 } },
  { text: 'oh nice', context: 'transferSuccess', traitWeights: { independent: 80, timid: 50 } },
  { text: 'wheee!', context: 'transferSuccess', traitWeights: { mischievous: 80 } },
  { text: 'cool, cool', context: 'transferSuccess', traitWeights: { independent: 70 } },
  { text: 'we did it!', context: 'transferSuccess', traitWeights: { curious: 70 } },

  // transferFail
  { text: 'oh no...', context: 'transferFail', traitWeights: { timid: 80, curious: 30 } },
  { text: 'what.', context: 'transferFail', traitWeights: { independent: 80 } },
  { text: 'lol', context: 'transferFail', traitWeights: { mischievous: 90 } },
  { text: 'darn', context: 'transferFail', traitWeights: { independent: 60, mischievous: 30 } },
  { text: '...', context: 'transferFail', traitWeights: { timid: 70 } },
  { text: 'try again?', context: 'transferFail', traitWeights: { curious: 70 } },
];
