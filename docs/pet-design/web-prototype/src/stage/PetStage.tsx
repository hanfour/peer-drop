import { useEffect, useState, type ReactNode } from 'react';

/**
 * Glassmorphic stage with a soft gradient backdrop, a translucent ground
 * line, and a 1Hz "breath bob" applied to its children.
 */
export function PetStage({ children }: { children: ReactNode }) {
  const [bobY, setBobY] = useState(0);

  useEffect(() => {
    const id = setInterval(() => {
      setBobY((prev) => (prev === 0 ? -2 : 0));
    }, 1000);
    return () => clearInterval(id);
  }, []);

  return (
    <div
      style={{
        position: 'relative',
        width: 360,
        height: 240,
        background: 'linear-gradient(180deg, #f5f5f7 60%, #d8d8dc 100%)',
        borderRadius: 12,
        overflow: 'hidden',
      }}
    >
      {/* Drop shadow */}
      <div
        style={{
          position: 'absolute',
          left: '50%',
          top: '74%',
          transform: 'translateX(-50%)',
          width: 96,
          height: 14,
          background:
            'radial-gradient(ellipse at center, rgba(0,0,0,0.22), transparent 70%)',
          filter: 'blur(2px)',
          pointerEvents: 'none',
        }}
      />
      <div
        style={{
          position: 'absolute',
          left: '50%',
          top: '60%',
          transform: `translate(-50%, ${bobY}px)`,
          transition: 'transform 1s ease-in-out',
        }}
      >
        {children}
      </div>
      <div
        style={{
          position: 'absolute',
          left: 0,
          right: 0,
          top: '78%',
          height: 1,
          background: 'rgba(0,0,0,0.06)',
        }}
      />
    </div>
  );
}
