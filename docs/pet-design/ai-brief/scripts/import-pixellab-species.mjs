#!/usr/bin/env node
// Batch-import 10 PixelLab species ZIPs into the prototype's
// docs/pet-design/web-prototype/public/data/species/ folder.
//
// Phase 2 (lifecycle): processes BOTH input directories so each species
// JSON gets a `stages` map (baby / adult / elder; bird splits adult into
// rooster + hen; ghost stays single-stage).
//
//   docs/pet-design/ai-brief/species-zips/         → adult stage of each species
//   docs/pet-design/ai-brief/species-zips-stages/  → baby/elder/rooster/hen
//
// Output schema (per-species JSON):
//   {
//     species, version, size, paletteIndex, paletteName, palette, ...,
//     displayScales:    { baby: 0.7, adult: 1.0, elder: 0.85 },
//     groundOffsetsY:   { baby: 31, adult: 33, elder: 32 },
//     stages: {
//       baby:  { idle: [...], walking: [...], happy: [...], tapReact: [...], scared: [...] },
//       adult: { ... },
//       elder: { ... }
//     },
//     // Back-compat: `baby` field still points at the adult stage frames so
//     // older v0/v1/v2 code paths and any test that reaches in for
//     // `data.baby.idle` keep working.
//     baby: { idle, walking, ... }
//   }
//
// Bird is special:
//   stages: { baby (= chick from species-zips/bird.zip),
//             'adult-rooster', 'adult-hen', elder }
//
// Ghost stays single-stage: stages: { adult: ... }
//
// Differences from the previous single-character v2 importer:
//   1) Operates over directories of ZIPs.
//   2) Quantizes each PNG to the species's PetPalette (6 slots).
//   3) Source size is 48×48; we keep it (renderer is size-agnostic).
//   4) Mirrors WEST horizontally so the East-facing baseline matches v1/v2.
//   5) Walking source: `animations/animation-*/west/frame_*.png` if
//      present, else fall back to a single-frame `rotations/west.png`.
//   6) Computes per-stage `groundOffsetY` = max y of any non-transparent
//      pixel across ALL rotations (after quantization) so the renderer
//      can bottom-anchor sprites and they always sit feet-on-ground.
//
// CLI: pure positional arguments, both optional (defaults to repo paths).
//   node import-pixellab-species.mjs [adults-zips-dir] [stages-zips-dir]
//
// License: PixelLab TOS — output may be used commercially in user
// projects, may NOT be used to train models.

import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import sharp from 'sharp';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const dataRoot = path.resolve(__dirname, '../../web-prototype/public/data');
const speciesDir = path.join(dataRoot, 'species');
const defaultAdultsDir = path.resolve(__dirname, '../species-zips');
const defaultStagesDir = path.resolve(__dirname, '../species-zips-stages');

const ALPHA_THRESHOLD = 128;

// --- PetPalettes (mirrors PeerDrop/Pet/Renderer/PetPalettes.swift) ----------
// Order: outline, primary, secondary, highlight, accent, pattern
const PET_PALETTES = [
  // 0: Warm Orange
  { name: 'Orange',    outline: '#5C3A1E', primary: '#F4A041', secondary: '#FEDE8A', highlight: '#FFF5D6', accent: '#E85D3A', pattern: '#D4853A' },
  // 1: Sky Blue
  { name: 'Sky Blue',  outline: '#2A4066', primary: '#6CB4EE', secondary: '#B8E0FF', highlight: '#E8F4FF', accent: '#3A7BD5', pattern: '#4A90D9' },
  // 2: Lavender
  { name: 'Lavender',  outline: '#4A3560', primary: '#B08CD8', secondary: '#D8C0F0', highlight: '#F0E8FF', accent: '#8B5FC7', pattern: '#9B70D0' },
  // 3: Fresh Green
  { name: 'Fresh Green', outline: '#2D5A1E', primary: '#7EC850', secondary: '#B8E890', highlight: '#E0FFD0', accent: '#4CAF50', pattern: '#5DBF60' },
  // 4: Cherry Pink
  { name: 'Cherry Pink', outline: '#6B3040', primary: '#F08080', secondary: '#FFB8C0', highlight: '#FFE8EC', accent: '#E85080', pattern: '#E86888' },
  // 5: Caramel
  { name: 'Caramel',   outline: '#4A2810', primary: '#C87830', secondary: '#E8B878', highlight: '#FFF0D8', accent: '#A05828', pattern: '#B06838' },
  // 6: Slate Gray
  { name: 'Slate Gray', outline: '#2A2A3A', primary: '#7888A0', secondary: '#A8B8C8', highlight: '#D8E0E8', accent: '#5068A0', pattern: '#6078A8' },
  // 7: Lemon Yellow
  { name: 'Lemon Yellow', outline: '#5A5020', primary: '#E8D44A', secondary: '#F0E888', highlight: '#FFFFF0', accent: '#C8A830', pattern: '#D0B838' },
];

// Slot order matches PetPalettes.swift's color(for:) function.
const SLOT_ORDER = ['outline', 'primary', 'secondary', 'highlight', 'accent', 'pattern'];

// Per-species canonical palette index. Drives the quantization target and
// the default colour the species ships with.
const SPECIES_PALETTE = {
  cat: 0,      // Orange — orange tabby
  dog: 0,      // Orange — shiba-inu prompt was orange
  rabbit: 6,   // Slate Gray — neutral grey for white-ish primary
  dragon: 3,   // Fresh Green
  bear: 5,     // Caramel — brown bear
  frog: 3,     // Fresh Green
  bird: 7,     // Lemon Yellow — chick
  slime: 3,    // Fresh Green — Dragon Quest slime
  ghost: 6,    // Slate Gray — neutral for white ghost
  octopus: 2,  // Lavender
};

// Display names (zh-Hant) for the picker UI. Matches Apple String Catalog tone.
const SPECIES_DISPLAY = {
  cat: { en: 'Cat', zh: '貓' },
  dog: { en: 'Dog', zh: '狗' },
  rabbit: { en: 'Rabbit', zh: '兔' },
  dragon: { en: 'Dragon', zh: '龍' },
  bear: { en: 'Bear', zh: '熊' },
  frog: { en: 'Frog', zh: '蛙' },
  bird: { en: 'Bird', zh: '鳥' },
  slime: { en: 'Slime', zh: '史萊姆' },
  ghost: { en: 'Ghost', zh: '幽靈' },
  octopus: { en: 'Octopus', zh: '章魚' },
};

// Per-stage display scale. Cat (adult) is the 1.0 baseline; everything
// else scales up/down so a bear reads bigger than a cat, a baby smaller
// than its adult, an octopus elder LARGER than its adult, etc.
//
// The renderer multiplies the version-derived `renderScale` by the active
// stage's value here. v0/v1/v2 don't read stages so they're unaffected.
const SPECIES_STAGE_SCALES = {
  cat:    { baby: 0.7,  adult: 1.0,  elder: 0.85 },
  dog:    { baby: 0.75, adult: 1.05, elder: 0.95 },
  rabbit: { baby: 0.55, adult: 0.75, elder: 0.7 },
  // Bird's "baby" is the chick from species-zips/bird.zip; "adult" splits
  // into rooster / hen sub-variants.
  bird:   { baby: 0.5,  'adult-rooster': 0.8, 'adult-hen': 0.8, elder: 0.7 },
  frog:   { baby: 0.45, adult: 0.65, elder: 0.6 },
  bear:   { baby: 0.9,  adult: 1.4,  elder: 1.25 },
  dragon: { baby: 0.65, adult: 1.0,  elder: 0.95 },
  slime:  { baby: 0.55, adult: 0.8,  elder: 0.65 },
  // Ghost is intentionally single-stage.
  ghost:  { adult: 0.85 },
  // Octopus elder is LARGER than adult (giant ancient cephalopod).
  octopus:{ baby: 0.6,  adult: 0.95, elder: 1.15 },
};

// Maps a stage ZIP filename suffix (after `<species>-`) to its canonical
// stage key in the output JSON. e.g. cat-baby.zip → 'baby',
// bird-rooster.zip → 'adult-rooster'.
const STAGE_SUFFIX_TO_KEY = {
  baby: 'baby',
  cub: 'baby',
  hatchling: 'baby',
  tadpole: 'baby',
  rooster: 'adult-rooster',
  hen: 'adult-hen',
  elder: 'elder',
};

// ---------------------------------------------------------------------------

function hexToRgb(hex) {
  const h = hex.replace('#', '');
  return {
    r: parseInt(h.slice(0, 2), 16),
    g: parseInt(h.slice(2, 4), 16),
    b: parseInt(h.slice(4, 6), 16),
  };
}

/**
 * Build a quantizer for a PetPalette: nearest-neighbour Euclidean RGB
 * search across the 6 slots. Returns palette index 1..6 (0 reserved for
 * transparent — never returned here).
 */
function buildQuantizer(palette) {
  const swatches = SLOT_ORDER.map((slot, i) => {
    const { r, g, b } = hexToRgb(palette[slot]);
    return { idx: i + 1, r, g, b };
  });
  return (r, g, b) => {
    let best = swatches[0].idx;
    let bestD = Infinity;
    for (const e of swatches) {
      const dr = r - e.r, dg = g - e.g, db = b - e.b;
      const d = dr * dr + dg * dg + db * db;
      if (d < bestD) { bestD = d; best = e.idx; }
    }
    return best;
  };
}

function ensureExtractedDir(input) {
  const stat = fs.statSync(input);
  if (stat.isDirectory()) return { dir: input, cleanup: () => {} };
  if (!input.toLowerCase().endsWith('.zip')) {
    throw new Error(`expected .zip or directory, got: ${input}`);
  }
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'pixellab-species-'));
  execFileSync('unzip', ['-q', input, '-d', tmp]);
  return {
    dir: tmp,
    cleanup: () => {
      try { fs.rmSync(tmp, { recursive: true, force: true }); }
      catch (e) { console.warn(`(cleanup) ${tmp}: ${e.message}`); }
    },
  };
}

async function loadRgba(filePath) {
  const { data, info } = await sharp(filePath).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  if (info.channels !== 4) throw new Error(`expected RGBA from ${filePath}`);
  return { data, width: info.width, height: info.height };
}

function quantizeBufferToGrid(buf, width, height, quantize) {
  const grid = [];
  for (let y = 0; y < height; y++) {
    const row = [];
    for (let x = 0; x < width; x++) {
      const o = (y * width + x) * 4;
      const a = buf[o + 3];
      if (a < ALPHA_THRESHOLD) row.push(0);
      else row.push(quantize(buf[o], buf[o + 1], buf[o + 2]));
    }
    grid.push(row);
  }
  return grid;
}

function mirrorGridHorizontal(grid) {
  return grid.map((row) => row.slice().reverse());
}

/**
 * Bottom-most non-transparent row index in a grid (0 = top row).
 * Returns -1 if the grid is fully transparent.
 *
 * Public so the importer's grounding pipeline can run it across all
 * frames+rotations and take max — chunky sprites with detached paws or
 * trailing accessories (e.g. bear's separated paws) need the
 * worst-case "feet" row to anchor at, otherwise the rim-light pass and
 * the sprite body land above ground.
 */
function bottomNonTransparentRow(grid) {
  for (let y = grid.length - 1; y >= 0; y--) {
    const row = grid[y];
    for (let x = 0; x < row.length; x++) {
      if (row[x] !== 0) return y;
    }
  }
  return -1;
}

function buildPaletteJson(palette) {
  // Slot 0 = transparent; slots 1..6 follow SLOT_ORDER.
  const out = { 0: 'transparent' };
  SLOT_ORDER.forEach((slot, i) => {
    out[String(i + 1)] = palette[slot];
  });
  return out;
}

/**
 * Extract a single stage's frame set from one PixelLab ZIP (or extracted
 * dir). Returns the per-action grids and the computed groundOffsetY.
 *
 * Pure: same input → same output. The caller composes per-stage frame
 * sets into the final species JSON.
 */
async function extractStageFromZip(zipPath, quantize) {
  const { dir, cleanup } = ensureExtractedDir(zipPath);
  try {
    const metaPath = path.join(dir, 'metadata.json');
    if (!fs.existsSync(metaPath)) throw new Error(`metadata.json missing in ${dir}`);
    const meta = JSON.parse(fs.readFileSync(metaPath, 'utf8'));
    const width = meta.character?.size?.width ?? 48;
    const height = meta.character?.size?.height ?? 48;

    const resolveFrame = (rel) => {
      const p = path.join(dir, rel);
      if (!fs.existsSync(p)) throw new Error(`frame missing: ${rel}`);
      return p;
    };

    // Idle/fallback source: rotations/west.png (after mirror → faces East).
    const westPath = resolveFrame(meta.frames.rotations.west);

    // Walking source: animation frames if present, else fall back to west.
    let walkingPaths = [];
    const animations = meta.frames?.animations ?? {};
    const animKey = Object.keys(animations)[0];
    if (animKey && Array.isArray(animations[animKey].west) && animations[animKey].west.length > 0) {
      walkingPaths = animations[animKey].west.map(resolveFrame);
    }
    const walkingFromAnim = walkingPaths.length > 0;

    // Load + quantize all needed PNGs (idle + walking).
    const renderPaths = walkingFromAnim ? [westPath, ...walkingPaths] : [westPath];
    const buffersByPath = new Map();
    for (const p of renderPaths) {
      buffersByPath.set(p, await loadRgba(p));
    }
    const quantizePath = (p) => {
      const { data, width: w, height: h } = buffersByPath.get(p);
      return mirrorGridHorizontal(quantizeBufferToGrid(data, w, h, quantize));
    };

    const idleGrid = quantizePath(westPath);
    const walkingGrids = walkingFromAnim ? walkingPaths.map(quantizePath) : [idleGrid];

    // Ground-offset detection: scan ALL rotations (not just the rendered
    // west/walking subset) and take the maximum bottom-most-y. Reason:
    // some species have asymmetric silhouettes (e.g. bear with one paw
    // dropping further) — the worst-case across rotations is the "feet"
    // line we want to anchor against.
    let groundOffsetY = -1;
    const rotPaths = Object.values(meta.frames.rotations).map(resolveFrame);
    for (const p of rotPaths) {
      const buf = buffersByPath.get(p) ?? (await loadRgba(p));
      const grid = mirrorGridHorizontal(
        quantizeBufferToGrid(buf.data, buf.width, buf.height, quantize),
      );
      const y = bottomNonTransparentRow(grid);
      if (y > groundOffsetY) groundOffsetY = y;
    }
    if (groundOffsetY < 0) groundOffsetY = Math.round(height * 0.875);

    return {
      width,
      height,
      groundOffsetY,
      walkingFromAnim,
      animKey,
      walkingFrames: walkingGrids.length,
      meta,
      frames: {
        idle: [idleGrid],
        walking: walkingGrids,
        happy: [idleGrid],
        tapReact: [idleGrid],
        scared: [idleGrid],
      },
    };
  } finally {
    cleanup();
  }
}

/**
 * List all *.zip files in a directory whose filename basename starts
 * with `<species>-`. Returns map of suffix → zip path. e.g. for `cat`
 * with stages dir, returns { 'baby': '.../cat-baby.zip', 'elder': ... }.
 */
function findStageZips(stagesDir, species) {
  if (!fs.existsSync(stagesDir)) return {};
  const out = {};
  const prefix = `${species}-`;
  for (const f of fs.readdirSync(stagesDir)) {
    if (!f.toLowerCase().endsWith('.zip')) continue;
    const base = path.basename(f, '.zip').toLowerCase();
    if (!base.startsWith(prefix)) continue;
    const suffix = base.slice(prefix.length);
    out[suffix] = path.join(stagesDir, f);
  }
  return out;
}

async function importSpecies(adultZipPath, stagesDir, species) {
  const paletteIdx = SPECIES_PALETTE[species];
  if (paletteIdx == null) throw new Error(`no palette mapping for species "${species}"`);
  const palette = PET_PALETTES[paletteIdx];
  const quantize = buildQuantizer(palette);

  // 1. Extract the adult stage from species-zips/<species>.zip.
  const adultStage = await extractStageFromZip(adultZipPath, quantize);

  // 2. Extract any auxiliary stages from species-zips-stages/.
  const stageZips = findStageZips(stagesDir, species);
  const auxStages = {};
  for (const [suffix, zipPath] of Object.entries(stageZips)) {
    auxStages[suffix] = await extractStageFromZip(zipPath, quantize);
  }

  // 3. Compose per-stage frame map and per-stage groundOffsetY map.
  //    Bird is special: its species-zips/bird.zip is actually the chick →
  //    becomes the `baby` stage; rooster/hen ZIPs become the adult variants.
  //    Ghost has no aux stages → single-stage adult.
  const stages = {};
  const groundOffsetsY = {};

  if (species === 'bird') {
    // Adult ZIP is the chick (= baby).
    stages.baby = adultStage.frames;
    groundOffsetsY.baby = adultStage.groundOffsetY;

    if (auxStages.rooster) {
      stages['adult-rooster'] = auxStages.rooster.frames;
      groundOffsetsY['adult-rooster'] = auxStages.rooster.groundOffsetY;
    }
    if (auxStages.hen) {
      stages['adult-hen'] = auxStages.hen.frames;
      groundOffsetsY['adult-hen'] = auxStages.hen.groundOffsetY;
    }
    if (auxStages.elder) {
      stages.elder = auxStages.elder.frames;
      groundOffsetsY.elder = auxStages.elder.groundOffsetY;
    }
  } else {
    // Default lifecycle: adult comes from species-zips/<species>.zip.
    stages.adult = adultStage.frames;
    groundOffsetsY.adult = adultStage.groundOffsetY;

    // Map any normalised baby suffix (baby / cub / hatchling / tadpole) → baby.
    const babySuffixes = ['baby', 'cub', 'hatchling', 'tadpole'];
    for (const suf of babySuffixes) {
      if (auxStages[suf]) {
        stages.baby = auxStages[suf].frames;
        groundOffsetsY.baby = auxStages[suf].groundOffsetY;
        break;
      }
    }
    if (auxStages.elder) {
      stages.elder = auxStages.elder.frames;
      groundOffsetsY.elder = auxStages.elder.groundOffsetY;
    }
  }

  const stageScales = SPECIES_STAGE_SCALES[species] ?? { adult: 1.0 };
  const adultMeta = adultStage.meta;
  const width = adultStage.width;
  const height = adultStage.height;

  const out = {
    version: 'v3',
    species,
    size: width,
    groundY: Math.round(height * 0.875), // ~42 of 48 (sceneographic — not the per-sprite anchor)
    meta: {
      groundY: Math.round(height * 0.875),
      eyeAnchor: { x: Math.round(width / 2), y: Math.round(height * 0.30) },
    },
    paletteIndex: paletteIdx,
    paletteName: palette.name,
    displayScales: stageScales,
    /**
     * Per-stage feet-row index (0 = top row). The renderer must compute
     *   effectiveCanvasY = stageGroundY - (groundOffsetY * scale)
     * so the sprite's bottom-most non-transparent pixel lands exactly on
     * the stage's ground line, regardless of displayScale.
     *
     * Computed from the worst-case bottom row across all 8 rotations of
     * each stage — handles asymmetric silhouettes (chunky bear paws,
     * dragon tail tips, etc.).
     */
    groundOffsetsY,
    _credit: {
      asset: `PixelLab AI ${species} (${adultMeta.character?.template_id ?? 'unknown template'})`,
      source: 'https://pixellab.ai',
      license: 'PixelLab Terms of Service — output may be used commercially in user projects. May NOT be used to train models.',
      prompt: adultMeta.character?.prompt,
      sourceCharacterId: adultMeta.character?.id,
      templateId: adultMeta.character?.template_id,
      generatedAt: adultMeta.character?.created_at,
    },
    _notes: {
      importer: 'docs/pet-design/ai-brief/scripts/import-pixellab-species.mjs',
      size: `${width}×${height} (PixelLab native, no downscale)`,
      paletteScheme: `Quantised to PetPalettes index ${paletteIdx} (${palette.name}). Slots: 1=outline 2=primary 3=secondary 4=highlight 5=accent 6=pattern. Swap the palette block at render time to recolour.`,
      stages: Object.keys(stages),
      mirrored: 'All frames mirrored horizontally during import (East-facing baseline; PixelLab west.png faces left).',
      groundOffsetsY: 'Per-stage feet-row index from the top of the 48-row canvas — used by PetStage to bottom-anchor sprites so all displayScales sit on the ground line correctly.',
    },
    palette: buildPaletteJson(palette),
    stages,
    /**
     * Back-compat: tests + v0/v1/v2 paths reach into `data.baby.idle`. We
     * mirror the canonical "default" stage here so they keep working
     * without any code change. The default stage is:
     *   - bird → 'adult-rooster' (or whichever adult variant we ship first)
     *   - everything else → 'adult'
     */
    baby:
      species === 'bird'
        ? stages['adult-rooster'] ?? stages.baby
        : stages.adult,
  };

  fs.mkdirSync(speciesDir, { recursive: true });
  const outPath = path.join(speciesDir, `${species}.json`);
  fs.writeFileSync(outPath, JSON.stringify(out, null, 0) + '\n');

  return {
    species,
    paletteIdx,
    paletteName: palette.name,
    stages: Object.keys(stages),
    walkingFrames: adultStage.walkingFrames,
    walkingFromAnim: adultStage.walkingFromAnim,
    outPath,
  };
}

async function main() {
  const adultsDir = path.resolve(process.cwd(), process.argv[2] ?? defaultAdultsDir);
  const stagesDir = path.resolve(process.cwd(), process.argv[3] ?? defaultStagesDir);
  if (!fs.existsSync(adultsDir) || !fs.statSync(adultsDir).isDirectory()) {
    throw new Error(`adults dir not found: ${adultsDir}`);
  }
  if (!fs.existsSync(stagesDir)) {
    console.warn(`(stages dir missing — proceeding with adult-only): ${stagesDir}`);
  }

  const zips = fs.readdirSync(adultsDir).filter((f) => f.toLowerCase().endsWith('.zip')).sort();
  if (zips.length === 0) {
    throw new Error(`no .zip files in ${adultsDir}`);
  }
  console.log(`Adults dir:  ${adultsDir} (${zips.length} ZIP${zips.length === 1 ? '' : 's'})`);
  console.log(`Stages dir:  ${stagesDir}`);

  const indexEntries = [];
  for (const z of zips) {
    const species = path.basename(z, '.zip').toLowerCase();
    process.stdout.write(`  • ${species.padEnd(8)} … `);
    try {
      const result = await importSpecies(path.join(adultsDir, z), stagesDir, species);
      const animTag = result.walkingFromAnim ? `walk:${result.walkingFrames}f` : 'walk:fallback';
      console.log(
        `palette=${result.paletteIdx} (${result.paletteName})  ${animTag}  stages=[${result.stages.join(', ')}]`,
      );
      const stageScales = SPECIES_STAGE_SCALES[species] ?? { adult: 1.0 };
      // Default-stage scale + key for legacy index field (`displayScale`) and
      // for App.tsx fallbacks. Bird's default is 'adult-rooster'.
      const defaultStageKey =
        species === 'bird' ? 'adult-rooster' : 'adult';
      const defaultDisplayScale = stageScales[defaultStageKey] ?? 1.0;
      indexEntries.push({
        species,
        displayEn: SPECIES_DISPLAY[species]?.en ?? species,
        displayZh: SPECIES_DISPLAY[species]?.zh ?? species,
        defaultPaletteIndex: result.paletteIdx,
        defaultPaletteName: result.paletteName,
        path: `species/${species}.json`,
        hasWalkAnimation: result.walkingFromAnim,
        // Default-stage scale, kept for back-compat with the v3 picker.
        displayScale: defaultDisplayScale,
        stages: result.stages,
        // Full per-stage scale table — App.tsx reads this to size pets per stage.
        displayScales: stageScales,
        defaultStage: defaultStageKey,
      });
    } catch (e) {
      console.error(`FAILED: ${e.message}`);
      throw e;
    }
  }

  // Write index.json — sort by display order matching the picker UI.
  const order = ['cat', 'dog', 'rabbit', 'bird', 'frog', 'bear', 'dragon', 'slime', 'ghost', 'octopus'];
  indexEntries.sort((a, b) => {
    const ai = order.indexOf(a.species);
    const bi = order.indexOf(b.species);
    return (ai === -1 ? 99 : ai) - (bi === -1 ? 99 : bi);
  });

  const indexJson = {
    version: 'v3',
    note: 'PixelLab AI Vadimsadovski-style species pack with multi-stage lifecycle. Each species ships baby/adult/elder stages (bird splits adult into rooster/hen; ghost is single-stage). Slots 1..6 = outline/primary/secondary/highlight/accent/pattern. Per-stage `displayScales` and `groundOffsetsY` drive bottom-anchored rendering so all sizes sit on the ground line correctly.',
    palettes: PET_PALETTES.map((p, i) => ({
      index: i,
      name: p.name,
      ...Object.fromEntries(SLOT_ORDER.map((s) => [s, p[s]])),
    })),
    species: indexEntries,
  };
  const indexPath = path.join(speciesDir, 'index.json');
  fs.writeFileSync(indexPath, JSON.stringify(indexJson, null, 2) + '\n');
  console.log(`\nWrote index: ${path.relative(process.cwd(), indexPath)}`);
  console.log(`Total species imported: ${indexEntries.length}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
