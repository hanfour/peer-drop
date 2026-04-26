export type Frame = number[][]; // 16x16 grid of palette indices
export type ActionFrames = Frame[];
export type Stage = 'baby' | 'child';

export type SpriteData = {
  meta: { groundY: number; eyeAnchor: { x: number; y: number } };
  baby: Record<string, ActionFrames>;
  child?: Record<string, ActionFrames>;
  /** Optional inline palette. When present, the renderer should prefer
   *  this over palettes.json — used by sprites whose colour scheme is
   *  intrinsic to the asset (e.g. the v1 imported chibi cat is
   *  grayscale-quantised and ships its own palette). */
  palette?: Palette;
};

export type Palette = Record<string, string>; // index → hex or "transparent"
