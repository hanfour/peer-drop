#!/usr/bin/env node
// Import AI-generated PNG output into the cat-v2.json sprite file.
//
// Pipeline (per state):
//   1) Load N source PNGs (one per frame, sorted by filename) from --input-dir.
//   2) Downscale each to --size x --size using sharp's nearest-neighbor kernel.
//   3) Quantize each pixel to the nearest palette color in palettes.json's
//      `default` palette (Euclidean distance in RGB; transparent passes
//      through if alpha < 128).
//   4) Output a 2D array of palette indices per frame.
//   5) Merge into cat-v2.json under <stage>.<state>; create file if missing.
//
// CLI:
//   node import-ai-sprite.mjs \
//     --state idle \
//     --stage baby \
//     --frames 4 \
//     --size 32 \
//     --input-dir ../raw-output/idle \
//     --palette default \
//     --out ../cat-v2.json
//
// All flags are optional except --state and --input-dir. Defaults:
//   --stage baby, --frames (autodetect from dir), --size 32,
//   --palette default, --out ../cat-v2.json
//
// NOTE: This is a SKELETON. It is syntactically valid and runnable, but has
// not been tested against real AI output yet. Once the user runs the first
// generation pass, expect to tune:
//   - palette quantization (may need dithering or perceptual color space)
//   - alpha threshold (currently 128)
//   - whether to crop transparent margins before downscaling
//   - frame ordering when AI exports a single sprite-strip image

import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import sharp from 'sharp';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const briefRoot = path.resolve(__dirname, '..');
const dataDir = path.resolve(__dirname, '../../web-prototype/public/data');

function parseArgs(argv) {
  const out = {};
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('--')) continue;
    const key = a.slice(2);
    const next = argv[i + 1];
    if (!next || next.startsWith('--')) {
      out[key] = true;
    } else {
      out[key] = next;
      i++;
    }
  }
  return out;
}

function usage() {
  console.log(`
Usage: node import-ai-sprite.mjs --state <name> --input-dir <path> [options]

Required:
  --state       Animation state key (idle|walking|happy|sleeping|tapReact|
                scared|running|sit|stretch|groom|eat|bellyUp)
  --input-dir   Directory of source PNGs (one per frame, sorted by filename)

Optional:
  --stage       baby | child  (default: baby)
  --frames      Number of frames to read; default = all PNGs in input-dir
  --size        Output canvas size in pixels (default: 32)
  --palette     Palette key from palettes.json (default: default)
  --out         Output JSON path (default: ../cat-v2.json)
  --help        Show this message
`);
}

function hexToRgb(hex) {
  const h = hex.replace('#', '');
  return [
    parseInt(h.slice(0, 2), 16),
    parseInt(h.slice(2, 4), 16),
    parseInt(h.slice(4, 6), 16),
  ];
}

function buildPaletteTable(palette) {
  // Returns array of { idx, rgb } excluding transparent (which is handled
  // by alpha threshold).
  const table = [];
  for (const [k, v] of Object.entries(palette)) {
    if (v === 'transparent') continue;
    table.push({ idx: Number(k), rgb: hexToRgb(v) });
  }
  return table;
}

function nearestPaletteIndex(r, g, b, table) {
  let best = table[0].idx;
  let bestD = Infinity;
  for (const e of table) {
    const dr = r - e.rgb[0];
    const dg = g - e.rgb[1];
    const db = b - e.rgb[2];
    const d = dr * dr + dg * dg + db * db;
    if (d < bestD) {
      bestD = d;
      best = e.idx;
    }
  }
  return best;
}

async function loadAndQuantize(filePath, size, paletteTable) {
  const { data, info } = await sharp(filePath)
    .resize(size, size, { kernel: sharp.kernel.nearest, fit: 'contain', background: { r: 0, g: 0, b: 0, alpha: 0 } })
    .ensureAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });

  const { width, height, channels } = info;
  if (width !== size || height !== size) {
    throw new Error(`unexpected size ${width}x${height} from ${filePath}`);
  }
  if (channels !== 4) {
    throw new Error(`expected 4 channels, got ${channels} from ${filePath}`);
  }

  const grid = [];
  for (let y = 0; y < size; y++) {
    const row = [];
    for (let x = 0; x < size; x++) {
      const o = (y * size + x) * 4;
      const r = data[o];
      const g = data[o + 1];
      const b = data[o + 2];
      const a = data[o + 3];
      if (a < 128) {
        row.push(0); // transparent
      } else {
        row.push(nearestPaletteIndex(r, g, b, paletteTable));
      }
    }
    grid.push(row);
  }
  return grid;
}

function loadOrInitOutput(outPath) {
  if (fs.existsSync(outPath)) {
    return JSON.parse(fs.readFileSync(outPath, 'utf8'));
  }
  return {
    meta: {
      groundY: 28,
      eyeAnchor: { x: 8, y: 10 },
      sourceVersion: 'v2-ai-assisted',
    },
    baby: {},
    child: {},
  };
}

async function main() {
  const args = parseArgs(process.argv);
  if (args.help || !args.state || !args['input-dir']) {
    usage();
    process.exit(args.help ? 0 : 1);
  }

  const state = args.state;
  const stage = args.stage || 'baby';
  const size = Number(args.size || 32);
  const paletteKey = args.palette || 'default';
  const inputDir = path.resolve(process.cwd(), args['input-dir']);
  const outPath = path.resolve(briefRoot, args.out || 'cat-v2.json');

  // Load palette
  const palettes = JSON.parse(fs.readFileSync(path.join(dataDir, 'palettes.json'), 'utf8'));
  const palette = palettes[paletteKey];
  if (!palette) throw new Error(`palette "${paletteKey}" not found`);
  const paletteTable = buildPaletteTable(palette);

  // Find frame files
  if (!fs.existsSync(inputDir)) {
    throw new Error(`input dir not found: ${inputDir}`);
  }
  const allFiles = fs
    .readdirSync(inputDir)
    .filter((f) => /\.png$/i.test(f))
    .sort();
  const want = args.frames ? Number(args.frames) : allFiles.length;
  const files = allFiles.slice(0, want);
  if (files.length === 0) throw new Error(`no PNGs found in ${inputDir}`);

  console.log(`Importing ${files.length} frames for ${stage}/${state} @ ${size}px (palette=${paletteKey})`);
  const frames = [];
  for (const f of files) {
    const full = path.join(inputDir, f);
    console.log(`  - ${f}`);
    const grid = await loadAndQuantize(full, size, paletteTable);
    frames.push(grid);
  }

  // Merge
  const out = loadOrInitOutput(outPath);
  if (!out[stage]) out[stage] = {};
  out[stage][state] = frames;

  fs.writeFileSync(outPath, JSON.stringify(out, null, 0) + '\n');
  console.log(`Wrote ${path.relative(briefRoot, outPath)} (state=${stage}/${state}, frames=${frames.length})`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
