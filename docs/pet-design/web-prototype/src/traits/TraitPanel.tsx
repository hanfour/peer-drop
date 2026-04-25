import type { Traits, TraitName } from './types';

const TRAIT_LABELS: Record<TraitName, string> = {
  independent: 'Independent',
  curious: 'Curious',
  timid: 'Timid',
  mischievous: 'Mischievous',
};

export function TraitPanel({
  traits,
  setTraits,
}: {
  traits: Traits;
  setTraits: (t: Traits) => void;
}) {
  return (
    <div
      style={{
        padding: 16,
        background: 'rgba(0,0,0,0.03)',
        borderRadius: 12,
        display: 'grid',
        gap: 10,
        minWidth: 280,
      }}
    >
      <div style={{ fontWeight: 600, fontSize: 14, color: '#666' }}>Personality</div>
      {(Object.keys(traits) as TraitName[]).map((k) => (
        <label
          key={k}
          style={{
            display: 'grid',
            gridTemplateColumns: '110px 1fr 32px',
            alignItems: 'center',
            gap: 8,
            fontSize: 13,
          }}
        >
          <span>{TRAIT_LABELS[k]}</span>
          <input
            type="range"
            min={0}
            max={100}
            value={traits[k]}
            onChange={(e) => setTraits({ ...traits, [k]: +e.target.value })}
            style={{ width: '100%' }}
          />
          <span
            style={{
              textAlign: 'right',
              color: '#888',
              fontFamily: 'ui-monospace',
            }}
          >
            {traits[k]}
          </span>
        </label>
      ))}
    </div>
  );
}
