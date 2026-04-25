import { useEffect, useState } from 'react';

/**
 * Pixel-art dialogue bubble: chunky 2px black border, off-white fill,
 * pointy bottom-center tail, monospace font. v1 replacement for the v0
 * rounded translucent bubble.
 *
 * Auto-dismisses after `durationMs` (default 2.2s). Latest-write-wins is
 * enforced by the parent — this component owns its own fade timer only.
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
        // Chunky pixel-art bubble: solid white fill, 2px solid border,
        // mono font. Box-shadow gives the inner-bevel that classic
        // RPG dialogue has.
        padding: '6px 10px 7px',
        background: '#FFF8E8',
        border: '2px solid #2A1F18',
        borderRadius: 2,
        boxShadow:
          'inset 1px 1px 0 #FFFFFF, inset -1px -1px 0 #E0D7BE, 0 2px 0 #2A1F18',
        fontFamily:
          "ui-monospace, 'SF Mono', 'SFMono-Regular', Menlo, Monaco, Consolas, monospace",
        fontSize: 11,
        fontWeight: 600,
        color: '#2A1F18',
        letterSpacing: '0.02em',
        whiteSpace: 'nowrap',
        animation: 'bubble-pop 0.2s steps(3, end)',
        pointerEvents: 'none',
        imageRendering: 'pixelated',
      }}
    >
      {text}
      {/* Tail: a chunky triangle pointing down toward the pet. We stack
          three rectangles to fake a pixel triangle and apply a thin
          dark outline. */}
      <div
        aria-hidden
        style={{
          position: 'absolute',
          left: '50%',
          bottom: -8,
          transform: 'translateX(-50%)',
          width: 8,
          height: 8,
          pointerEvents: 'none',
        }}
      >
        <div
          style={{
            position: 'absolute',
            left: 1,
            top: 0,
            width: 6,
            height: 2,
            background: '#FFF8E8',
            borderLeft: '2px solid #2A1F18',
            borderRight: '2px solid #2A1F18',
            boxSizing: 'border-box',
          }}
        />
        <div
          style={{
            position: 'absolute',
            left: 2,
            top: 2,
            width: 4,
            height: 2,
            background: '#FFF8E8',
            borderLeft: '2px solid #2A1F18',
            borderRight: '2px solid #2A1F18',
            boxSizing: 'border-box',
          }}
        />
        <div
          style={{
            position: 'absolute',
            left: 3,
            top: 4,
            width: 2,
            height: 2,
            background: '#2A1F18',
          }}
        />
      </div>
      <style>{`
        @keyframes bubble-pop {
          0%   { transform: translate(-50%, -90%) scale(0.0); opacity: 0; }
          50%  { transform: translate(-50%, -100%) scale(1.1); opacity: 1; }
          100% { transform: translate(-50%, -110%) scale(1); opacity: 1; }
        }
      `}</style>
    </div>
  );
}
