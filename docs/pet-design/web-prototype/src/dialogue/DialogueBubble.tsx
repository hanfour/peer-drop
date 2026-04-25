import { useEffect, useState } from 'react';

/**
 * A small floating bubble anchored above the pet. Auto-dismisses after
 * `durationMs` (default 2.2s). Latest-write-wins is enforced by the parent
 * — this component just owns its own fade timer.
 */
export function DialogueBubble({
  text,
  durationMs = 2200,
  onDismissed,
}: {
  text: string;
  durationMs?: number;
  onDismissed?: () => void;
}) {
  const [visible, setVisible] = useState(true);
  useEffect(() => {
    setVisible(true);
    const id = setTimeout(() => {
      setVisible(false);
      onDismissed?.();
    }, durationMs);
    return () => clearTimeout(id);
  }, [text, durationMs, onDismissed]);

  if (!visible) return null;
  return (
    <div
      style={{
        position: 'absolute',
        left: '50%',
        top: 0,
        transform: 'translate(-50%, -110%)',
        padding: '6px 12px',
        borderRadius: 12,
        background: 'rgba(255,255,255,0.85)',
        backdropFilter: 'blur(4px)',
        WebkitBackdropFilter: 'blur(4px)',
        border: '1px solid rgba(0,0,0,0.08)',
        boxShadow: '0 2px 8px rgba(0,0,0,0.08)',
        fontSize: 13,
        color: '#222',
        whiteSpace: 'nowrap',
        animation: 'bubble-in 0.25s ease-out',
        pointerEvents: 'none',
      }}
    >
      {text}
      <style>{`
        @keyframes bubble-in {
          0% { transform: translate(-50%, -90%) scale(0.6); opacity: 0; }
          100% { transform: translate(-50%, -110%) scale(1); opacity: 1; }
        }
      `}</style>
    </div>
  );
}
