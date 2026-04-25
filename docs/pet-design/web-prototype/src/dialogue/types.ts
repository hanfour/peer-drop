import type { TraitName } from '../traits/types';

export type DialogueContext =
  | 'idle'
  | 'greeting'
  | 'tap'
  | 'transferSuccess'
  | 'transferFail';

export type DialogueLine = {
  text: string;
  context: DialogueContext;
  /** 0..100; higher = more likely for that trait */
  traitWeights: Partial<Record<TraitName, number>>;
};
