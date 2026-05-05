export type TraitName = 'independent' | 'curious' | 'timid' | 'mischievous';
export type Traits = Record<TraitName, number>;

export const defaultTraits: Traits = {
  independent: 50,
  curious: 70,
  timid: 30,
  mischievous: 40,
};

export function dominantTrait(t: Traits): TraitName {
  return (Object.entries(t) as [TraitName, number][])
    .sort((a, b) => b[1] - a[1])[0][0];
}
