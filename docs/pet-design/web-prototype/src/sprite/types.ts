export type Frame = number[][]; // 16x16 grid of palette indices
export type ActionFrames = Frame[];
export type Stage = 'baby' | 'child';

/**
 * Lifecycle stage key. v3 species ship multiple stages; the picker UI
 * currently exposes baby / adult / elder. Bird splits adult into two
 * sub-variants (rooster + hen). Ghost is single-stage (adult only).
 */
export type LifecycleStageKey =
  | 'baby'
  | 'adult'
  | 'adult-rooster'
  | 'adult-hen'
  | 'elder';

export type StageFrames = Record<string, ActionFrames>;

export type SpriteData = {
  meta: { groundY: number; eyeAnchor: { x: number; y: number } };
  /** Back-compat: tests + v0/v1/v2 paths read `baby.idle`. v3 mirrors the
   *  default stage's frames here so legacy callers keep working. */
  baby: StageFrames;
  child?: StageFrames;
  /** v3-only: full per-stage frame map. Absent on v0/v1/v2. */
  stages?: Partial<Record<LifecycleStageKey, StageFrames>>;
  /** v3-only: per-stage display scale multiplier. */
  displayScales?: Partial<Record<LifecycleStageKey, number>>;
  /** v3-only: per-stage feet-row index (0 = top), used for bottom-anchored
   *  rendering. The renderer computes
   *    canvasY = stageGroundY - groundOffsetY * scale
   *  so the sprite's bottom-most non-transparent pixel sits exactly on
   *  the stage's ground line. */
  groundOffsetsY?: Partial<Record<LifecycleStageKey, number>>;
  /** Optional inline palette. When present, the renderer should prefer
   *  this over palettes.json — used by sprites whose colour scheme is
   *  intrinsic to the asset (e.g. the v1 imported chibi cat is
   *  grayscale-quantised and ships its own palette). */
  palette?: Palette;
};

export type Palette = Record<string, string>; // index → hex or "transparent"
