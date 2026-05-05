#!/usr/bin/env node
// Import PixelLab AI image-to-image output into cat-v2.json sprite file.
//
// Pipeline:
//   1) Accept either a .zip or a directory containing the PixelLab export.
//   2) Read metadata.json (PixelLab schema 2.0). Source PNGs are 76×76.
//   3) For each PNG: downscale 76→32 with sharp's nearest-neighbor kernel.
//      Note: 76 doesn't divide evenly by 32 — slight precision loss is
//      expected. Nearest-neighbor preserves the chibi color blocks better
//      than bilinear/lanczos at this ratio.
//   4) Scan all PNGs together to collect unique opaque RGB triples (alpha
//      threshold 128). Sort by frequency and cap at MAX_COLORS=12 — colors
//      beyond the cap snap to the nearest of the top-12 via Euclidean RGB
//      distance.
//   5) Build a `palette` object: index 0 = transparent; indices 1..N =
//      hex strings sorted by HSV (luminance-ish) for stable ordering.
//   6) Map source files → animation states:
//        walking → animations/animation-fe8a64c2/west/frame_*.png  (4 frames)
//        idle    → rotations/south-west.png                        (single-frame fallback*)
//        happy   → rotations/south-west.png                        (single-frame fallback)
//        tapReact→ rotations/south-west.png                        (single-frame fallback)
//        scared  → rotations/south-west.png                        (single-frame fallback)
//      *Why south-west not west? In this PixelLab export the south.png and
//       east.png files are just trimmed copies of the v0 cat reference (323
//       and 317 bytes — far smaller than the 800–940-byte AI-generated
//       directions). west.png is genuine AI output (834 bytes), but
//       south-west reads as a more 3D-aware "facing-the-camera" idle pose.
//   7) Output cat-v2.json matching the cat-v1.json schema:
//        { version, size:32, meta:{groundY,eyeAnchor}, _credit, _notes,
//          palette:{...}, baby:{idle, walking, happy, tapReact, scared} }
//
// CLI:
//   node import-pixellab.mjs <zip-or-dir>
//   node import-pixellab.mjs ../raw-output-pixellab.zip
//
// License note: PixelLab free-tier output may be used commercially in user
// projects; it MAY NOT be used to train models. See PixelLab TOS.

import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import sharp from 'sharp';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const briefRoot = path.resolve(__dirname, '..');
const dataDir = path.resolve(__dirname, '../../web-prototype/public/data');

const TARGET_SIZE = 32;
const MAX_COLORS = 12; // cap palette (excluding transparent index 0)
const ALPHA_THRESHOLD = 128;

function rgbToHex(r, g, b) {
  const h = (n) => n.toString(16).padStart(2, '0');
  return `#${h(r)}${h(g)}${h(b)}`.toUpperCase();
}

function rgbToHsv(r, g, b) {
  const rn = r / 255, gn = g / 255, bn = b / 255;
  const max = Math.max(rn, gn, bn);
  const min = Math.min(rn, gn, bn);
  const d = max - min;
  let h = 0;
  if (d !== 0) {
    if (max === rn) h = ((gn - bn) / d) % 6;
    else if (max === gn) h = (bn - rn) / d + 2;
    else h = (rn - gn) / d + 4;
    h *= 60;
    if (h < 0) h += 360;
  }
  const s = max === 0 ? 0 : d / max;
  const v = max;
  return [h, s, v];
}

function ensureExtractedDir(input) {
  const stat = fs.statSync(input);
  if (stat.isDirectory()) {
    return { dir: input, cleanup: () => {} };
  }
  if (!input.toLowerCase().endsWith('.zip')) {
    throw new Error(`expected .zip or directory, got: ${input}`);
  }
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'pixellab-'));
  console.log(`Extracting ${path.basename(input)} → ${tmp}`);
  execFileSync('unzip', ['-q', input, '-d', tmp], { stdio: 'inherit' });
  return {
    dir: tmp,
    cleanup: () => {
      try {
        fs.rmSync(tmp, { recursive: true, force: true });
      } catch (e) {
        console.warn(`(cleanup) could not remove ${tmp}: ${e.message}`);
      }
    },
  };
}

async function loadResizedRgba(filePath) {
  const { data, info } = await sharp(filePath)
    .resize(TARGET_SIZE, TARGET_SIZE, {
      kernel: sharp.kernel.nearest,
      fit: 'fill',
    })
    .ensureAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });
  if (info.width !== TARGET_SIZE || info.height !== TARGET_SIZE) {
    throw new Error(`unexpected size ${info.width}x${info.height} from ${filePath}`);
  }
  if (info.channels !== 4) {
    throw new Error(`expected RGBA, got ${info.channels} channels from ${filePath}`);
  }
  return data; // Buffer of size*size*4
}

// Collect color frequency across ALL frames so the cap-to-12 step uses
// global frequency, not per-frame.
function tallyColors(frameBuffers) {
  const counts = new Map(); // 'r,g,b' → count
  for (const buf of frameBuffers) {
    for (let i = 0; i < buf.length; i += 4) {
      const a = buf[i + 3];
      if (a < ALPHA_THRESHOLD) continue;
      const r = buf[i];
      const g = buf[i + 1];
      const b = buf[i + 2];
      const k = `${r},${g},${b}`;
      counts.set(k, (counts.get(k) ?? 0) + 1);
    }
  }
  return counts;
}

function buildPalette(colorCounts) {
  // Sort all colors by frequency desc, take top MAX_COLORS for the
  // canonical palette. Anything else maps via nearest-neighbor.
  const all = [...colorCounts.entries()]
    .map(([k, count]) => {
      const [r, g, b] = k.split(',').map(Number);
      return { r, g, b, count };
    })
    .sort((a, b) => b.count - a.count);

  const top = all.slice(0, MAX_COLORS);
  // Order palette indices by HSV (sort by hue, then value) so nearby colors
  // sit next to each other in the JSON — easier to eyeball.
  const ordered = [...top].sort((a, b) => {
    const [ha, sa, va] = rgbToHsv(a.r, a.g, a.b);
    const [hb, sb, vb] = rgbToHsv(b.r, b.g, b.b);
    if (Math.abs(ha - hb) > 1) return ha - hb;
    if (Math.abs(va - vb) > 0.05) return va - vb;
    return sa - sb;
  });

  const palette = { 0: 'transparent' };
  ordered.forEach((c, i) => {
    palette[String(i + 1)] = rgbToHex(c.r, c.g, c.b);
  });

  // For nearest-neighbor lookup keep an array form excluding transparent.
  const lookup = ordered.map((c, i) => ({ idx: i + 1, r: c.r, g: c.g, b: c.b }));

  return { palette, lookup, droppedColors: all.length - top.length };
}

function nearestPaletteIndex(r, g, b, lookup) {
  let best = lookup[0].idx;
  let bestD = Infinity;
  for (const e of lookup) {
    const dr = r - e.r;
    const dg = g - e.g;
    const db = b - e.b;
    const d = dr * dr + dg * dg + db * db;
    if (d < bestD) {
      bestD = d;
      best = e.idx;
    }
  }
  return best;
}

function quantizeBufferToGrid(buf, lookup) {
  const grid = [];
  for (let y = 0; y < TARGET_SIZE; y++) {
    const row = [];
    for (let x = 0; x < TARGET_SIZE; x++) {
      const o = (y * TARGET_SIZE + x) * 4;
      const a = buf[o + 3];
      if (a < ALPHA_THRESHOLD) {
        row.push(0);
      } else {
        row.push(nearestPaletteIndex(buf[o], buf[o + 1], buf[o + 2], lookup));
      }
    }
    grid.push(row);
  }
  return grid;
}

// PixelLab generates West-direction frames facing left. The prototype's
// flip logic was designed against v1 Shepardskin's East-facing baseline
// (frames face right; flipped: true mirrors them to face left). Mirror
// every output grid horizontally so v2 matches the East-facing convention
// and the prototype's flipped flag does the right thing.
function mirrorGridHorizontal(grid) {
  return grid.map((row) => row.slice().reverse());
}

async function main() {
  const inputArg = process.argv[2];
  if (!inputArg) {
    console.error('Usage: node import-pixellab.mjs <path-to-zip-or-dir>');
    process.exit(1);
  }

  const inputResolved = path.resolve(process.cwd(), inputArg);
  if (!fs.existsSync(inputResolved)) {
    throw new Error(`input not found: ${inputResolved}`);
  }

  const { dir, cleanup } = ensureExtractedDir(inputResolved);

  try {
    const metaPath = path.join(dir, 'metadata.json');
    if (!fs.existsSync(metaPath)) {
      throw new Error(`metadata.json not found in ${dir}`);
    }
    const meta = JSON.parse(fs.readFileSync(metaPath, 'utf8'));
    console.log(`PixelLab export v${meta.export_version} • ${meta.character?.name?.slice(0, 60) ?? '(unknown)'}…`);

    // Resolve the file paths relative to the extracted dir.
    const resolveFrame = (rel) => {
      const p = path.join(dir, rel);
      if (!fs.existsSync(p)) throw new Error(`frame missing: ${rel}`);
      return p;
    };

    // Walking (4 frames) — lifted from animation-fe8a64c2/west/frame_*.png.
    const animKey = Object.keys(meta.frames?.animations ?? {})[0];
    if (!animKey) throw new Error('no animations found in metadata');
    const walkingPaths = (meta.frames.animations[animKey].west ?? []).map(resolveFrame);
    if (walkingPaths.length !== 4) {
      console.warn(`expected 4 walking frames, got ${walkingPaths.length}`);
    }

    // Idle/etc. fallback — rotations/south-west.png is genuine AI output,
    // unlike rotations/south.png and rotations/east.png which are tiny
    // (~320-byte) reference echoes.
    const swPath = resolveFrame(meta.frames.rotations['south-west']);

    // Load + resize everything once. We need them all in memory to build a
    // global palette from frequency.
    const filesToLoad = [
      { key: 'idle', path: swPath, role: 'rotation/south-west (single-frame fallback)' },
      ...walkingPaths.map((p, i) => ({ key: `walking_${i}`, path: p, role: `walking frame ${i}` })),
      { key: 'happy', path: swPath, role: 'rotation/south-west (single-frame fallback)' },
      { key: 'tapReact', path: swPath, role: 'rotation/south-west (single-frame fallback)' },
      { key: 'scared', path: swPath, role: 'rotation/south-west (single-frame fallback)' },
    ];

    // Deduplicate the actual disk reads — multiple keys can share the same path.
    const uniquePaths = [...new Set(filesToLoad.map((f) => f.path))];
    const buffersByPath = new Map();
    for (const p of uniquePaths) {
      console.log(`  resize ${path.basename(p)} (76→32 nearest)`);
      buffersByPath.set(p, await loadResizedRgba(p));
    }

    // Global palette tally
    const counts = tallyColors([...buffersByPath.values()]);
    const { palette, lookup, droppedColors } = buildPalette(counts);
    console.log(`Palette: ${Object.keys(palette).length - 1} colors (transparent + ${Object.keys(palette).length - 1}). ${droppedColors} unique source colors mapped via nearest-neighbor.`);
    for (const [idx, hex] of Object.entries(palette)) {
      console.log(`  ${idx}: ${hex}`);
    }

    // Quantize each frame, then mirror horizontally to East-facing baseline
    // (see mirrorGridHorizontal docs).
    const quantize = (p) => mirrorGridHorizontal(quantizeBufferToGrid(buffersByPath.get(p), lookup));

    const idleGrid = quantize(swPath);
    const walkingGrids = walkingPaths.map(quantize);
    // happy / tapReact / scared all reuse the south-west single frame for
    // now — see _notes in the output JSON.

    const out = {
      version: 'v2',
      size: TARGET_SIZE,
      groundY: 28,
      meta: {
        groundY: 28,
        eyeAnchor: { x: 16, y: 12 },
      },
      _credit: {
        asset: 'PixelLab AI chibi cat (image-to-image)',
        author: 'PixelLab AI (image-to-image, image reference: PeerDrop v0 cat)',
        source: 'https://pixellab.ai',
        license: 'PixelLab Terms of Service — free-tier output may be used commercially in user projects. May NOT be used to train models.',
        prompt: meta.character?.prompt,
        sourceCharacterId: meta.character?.id,
        generatedAt: meta.character?.created_at,
      },
      _notes: {
        importer: 'docs/pet-design/ai-brief/scripts/import-pixellab.mjs',
        downsample: '76×76 → 32×32 via sharp nearest-neighbor (76 does not divide evenly by 32; slight precision loss expected).',
        paletteCap: `${MAX_COLORS} colors max (excluding transparent). Built from global frequency across all imported frames; overflow snapped via Euclidean RGB distance.`,
        frameSourceMapping: {
          idle: 'rotations/south-west.png (single-frame fallback — user may regenerate as proper idle animation)',
          walking: 'animations/animation-fe8a64c2/west/frame_{000..003}.png (4 frames, AI-generated)',
          happy: 'rotations/south-west.png (single-frame fallback)',
          tapReact: 'rotations/south-west.png (single-frame fallback)',
          scared: 'rotations/south-west.png (single-frame fallback)',
        },
        skippedSources: [
          'rotations/south.png and rotations/east.png — PixelLab echoed back trimmed copies of our v0 reference (323 and 317 bytes) rather than generating new South/East views. Re-run with stricter prompts to fill these.',
        ],
        mirrored: 'All frames mirrored horizontally during import to face East (right) — matches v1 Shepardskin convention so the prototype’s flipped flag works consistently across sprite versions.',
      },
      palette,
      baby: {
        idle: [idleGrid],
        walking: walkingGrids,
        happy: [idleGrid],
        tapReact: [idleGrid],
        scared: [idleGrid],
      },
    };

    const outPath = path.join(dataDir, 'cat-v2.json');
    fs.writeFileSync(outPath, JSON.stringify(out, null, 0) + '\n');
    console.log(`\nWrote ${path.relative(briefRoot, outPath)}`);
    console.log(`  idle:     1 frame`);
    console.log(`  walking:  ${walkingGrids.length} frames`);
    console.log(`  happy:    1 frame (south-west fallback)`);
    console.log(`  tapReact: 1 frame (south-west fallback)`);
    console.log(`  scared:   1 frame (south-west fallback)`);
  } finally {
    cleanup();
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
