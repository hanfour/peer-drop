export type Frame = number[][]; // 16x16 grid of palette indices
export type ActionFrames = Frame[];
export type Stage = 'baby' | 'child';

export type SpriteData = {
  meta: { groundY: number; eyeAnchor: { x: number; y: number } };
  baby: Record<string, ActionFrames>;
  child?: Record<string, ActionFrames>;
};

export type Palette = Record<string, string>; // index → hex or "transparent"
