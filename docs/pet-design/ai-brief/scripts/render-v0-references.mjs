#!/usr/bin/env node
// Render PeerDrop v0 cat sprite frames into PNG references for AI
// generation tools (Midjourney / Retro Diffusion / PixelLab.ai).
//
// Inputs:
//   ../../web-prototype/public/data/cat.json
//   ../../web-prototype/public/data/palettes.json   (default palette)
//
// Outputs (../references/):
//   <state>-1x.png   (16x16,  pixel-perfect)
//   <state>-4x.png   (64x64,  nearest-neighbor)
//   <state>-16x.png  (256x256, nearest-neighbor)
//   <state>-32x.png  (512x512, nearest-neighbor)
//   baby-sheet.png   (all baby states in a row, 4x)
//   child-sheet.png  (all child states in a row, 4x)
//   hero-reference.png (512x512 large hero of baby/idle[0])
//
// Where <state> = baby-idle | baby-walking | baby-happy | baby-sleeping
//               | baby-tapReact | baby-scared | child-idle | child-walking
//
// Run from the script directory or anywhere — paths are resolved against
// __dirname.

import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import sharp from 'sharp';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const briefRoot = path.resolve(__dirname, '..');
const dataDir = path.resolve(__dirname, '../../web-prototype/public/data');
const outDir = path.resolve(briefRoot, 'references');

fs.mkdirSync(outDir, { recursive: true });

const cat = JSON.parse(fs.readFileSync(path.join(dataDir, 'cat.json'), 'utf8'));
const palettes = JSON.parse(fs.readFileSync(path.join(dataDir, 'palettes.json'), 'utf8'));
const palette = palettes.default;

const FRAME_SIZE = 16;
const SCALES = [1, 4, 16, 32];

const TARGETS = [
  { stage: 'baby', state: 'idle' },
  { stage: 'baby', state: 'walking' },
  { stage: 'baby', state: 'happy' },
  { stage: 'baby', state: 'sleeping' },
  { stage: 'baby', state: 'tapReact' },
  { stage: 'baby', state: 'scared' },
  { stage: 'child', state: 'idle' },
  { stage: 'child', state: 'walking' },
];

/** Convert "#RRGGBB" or "transparent" -> [r,g,b,a]. */
function hexToRgba(hex) {
  if (!hex || hex === 'transparent') return [0, 0, 0, 0];
  const h = hex.replace('#', '');
  const r = parseInt(h.slice(0, 2), 16);
  const g = parseInt(h.slice(2, 4), 16);
  const b = parseInt(h.slice(4, 6), 16);
  return [r, g, b, 255];
}

/** 2D array of palette indices -> raw RGBA buffer (row-major). */
function frameToRgba(frame) {
  const h = frame.length;
  const w = frame[0].length;
  const buf = Buffer.alloc(w * h * 4);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const idx = frame[y][x];
      const hex = palette[String(idx)] ?? 'transparent';
      const [r, g, b, a] = hexToRgba(hex);
      const o = (y * w + x) * 4;
      buf[o] = r;
      buf[o + 1] = g;
      buf[o + 2] = b;
      buf[o + 3] = a;
    }
  }
  return { buf, w, h };
}

async function writeScaled(frame, baseName) {
  const { buf, w, h } = frameToRgba(frame);
  const baseImg = sharp(buf, { raw: { width: w, height: h, channels: 4 } });
  for (const scale of SCALES) {
    const outPath = path.join(outDir, `${baseName}-${scale}x.png`);
    await baseImg
      .clone()
      .resize(w * scale, h * scale, { kernel: sharp.kernel.nearest })
      .png({ compressionLevel: 9 })
      .toFile(outPath);
    console.log(`  wrote ${path.relative(briefRoot, outPath)}`);
  }
}

async function writeSheet(stage, states, scale = 4) {
  // Horizontal strip of first frame of each state.
  const tileW = FRAME_SIZE * scale;
  const tileH = FRAME_SIZE * scale;
  const sheetW = tileW * states.length;
  const sheetH = tileH;

  const composites = [];
  for (let i = 0; i < states.length; i++) {
    const state = states[i];
    const frames = cat[stage]?.[state];
    if (!frames || !frames[0]) continue;
    const { buf, w, h } = frameToRgba(frames[0]);
    const tileBuf = await sharp(buf, { raw: { width: w, height: h, channels: 4 } })
      .resize(tileW, tileH, { kernel: sharp.kernel.nearest })
      .png()
      .toBuffer();
    composites.push({ input: tileBuf, left: i * tileW, top: 0 });
  }

  const sheetPath = path.join(outDir, `${stage}-sheet.png`);
  await sharp({
    create: {
      width: sheetW,
      height: sheetH,
      channels: 4,
      background: { r: 0, g: 0, b: 0, alpha: 0 },
    },
  })
    .composite(composites)
    .png({ compressionLevel: 9 })
    .toFile(sheetPath);
  console.log(`  wrote ${path.relative(briefRoot, sheetPath)}`);
}

async function writeHero() {
  const frame = cat.baby.idle[0];
  const { buf, w, h } = frameToRgba(frame);
  const heroPath = path.join(outDir, 'hero-reference.png');
  await sharp(buf, { raw: { width: w, height: h, channels: 4 } })
    .resize(512, 512, { kernel: sharp.kernel.nearest })
    .png({ compressionLevel: 9 })
    .toFile(heroPath);
  console.log(`  wrote ${path.relative(briefRoot, heroPath)}`);
}

async function main() {
  console.log(`Rendering v0 cat references -> ${path.relative(briefRoot, outDir)}/`);

  for (const t of TARGETS) {
    const frames = cat[t.stage]?.[t.state];
    if (!frames || frames.length === 0) {
      console.warn(`  skip ${t.stage}/${t.state} (no frames)`);
      continue;
    }
    const baseName = `${t.stage}-${t.state}`;
    console.log(`- ${baseName} (frame 0 of ${frames.length})`);
    await writeScaled(frames[0], baseName);
  }

  console.log('- baby-sheet');
  await writeSheet('baby', ['idle', 'walking', 'happy', 'sleeping', 'tapReact', 'scared']);

  console.log('- child-sheet');
  await writeSheet('child', ['idle', 'walking', 'happy', 'sleeping', 'tapReact', 'scared']);

  console.log('- hero-reference');
  await writeHero();

  console.log('Done.');
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
