// Render PeerDrop v0 slime + octopus baby idle frame 0 to PNG references
// for PixelLab image-to-image. Outputs 4 PNGs at 256×256 (16× nearest-neighbor).
import sharp from 'sharp';
import fs from 'node:fs';
import path from 'node:path';
import url from 'node:url';

const __dirname = path.dirname(url.fileURLToPath(import.meta.url));
const OUT = path.join(__dirname, '..', 'v0-references');
fs.mkdirSync(OUT, { recursive: true });

// Sprites lifted from PeerDrop/Pet/Sprites/{Slime,Octopus}SpriteData.swift baby.idle[0]
const slimeFrame = [
  [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
  [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
  [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
  [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
  [0,0,0,0,0,0,0,1,0,0,0,0,0,0,0,0],
  [0,0,0,0,0,0,1,2,1,0,0,0,0,0,0,0],
  [0,0,0,0,0,1,2,4,2,1,0,0,0,0,0,0],
  [0,0,0,0,1,2,2,2,2,2,1,0,0,0,0,0],
  [0,0,0,1,2,2,2,2,2,2,2,1,0,0,0,0],
  [0,0,0,1,2,5,2,2,2,5,2,1,0,0,0,0],
  [0,0,0,1,2,2,2,3,2,2,2,1,0,0,0,0],
  [0,0,1,2,2,2,2,2,2,2,2,2,1,0,0,0],
  [0,0,1,2,2,2,2,2,2,2,2,2,1,0,0,0],
  [0,0,0,1,1,1,1,1,1,1,1,1,0,0,0,0],
  [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
  [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
];

const octopusFrame = [
  [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
  [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
  [0,0,0,0,1,1,1,1,1,1,0,0,0,0,0,0],
  [0,0,0,1,2,2,2,2,2,2,1,0,0,0,0,0],
  [0,0,1,2,2,5,2,2,5,2,2,1,0,0,0,0],
  [0,0,1,2,2,2,2,2,2,2,2,1,0,0,0,0],
  [0,0,1,2,2,2,3,3,2,2,2,1,0,0,0,0],
  [0,0,1,2,2,2,2,2,2,2,2,1,0,0,0,0],
  [0,0,0,1,2,2,2,2,2,2,1,0,0,0,0,0],
  [0,0,1,2,0,1,2,2,1,0,2,1,0,0,0,0],
  [0,1,2,0,0,0,1,1,0,0,0,2,1,0,0,0],
  [0,1,0,0,0,0,1,1,0,0,0,0,1,0,0,0],
  [0,0,1,0,0,1,0,0,1,0,0,1,0,0,0,0],
  [0,0,0,1,1,0,0,0,0,1,1,0,0,0,0,0],
  [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
  [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
];

// PetPalettes: index 3 (Fresh Green) for slime, index 2 (Lavender) for octopus
const slimePalette = {
  0: null,
  1: [0x2D, 0x5A, 0x1E],
  2: [0x7E, 0xC8, 0x50],
  3: [0xB8, 0xE8, 0x90],
  4: [0xE0, 0xFF, 0xD0],
  5: [0x4C, 0xAF, 0x50],
};
const octopusPalette = {
  0: null,
  1: [0x4A, 0x35, 0x60],
  2: [0xB0, 0x8C, 0xD8],
  3: [0xD8, 0xC0, 0xF0],
  4: [0xF0, 0xE8, 0xFF],
  5: [0x8B, 0x5F, 0xC7],
};

async function render(frame, palette, outPath, scale) {
  const W = frame[0].length;
  const H = frame.length;
  const buf = Buffer.alloc(W * H * 4);
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      const idx = frame[y][x];
      const c = palette[idx];
      const o = (y * W + x) * 4;
      if (c == null) {
        buf[o] = 0; buf[o + 1] = 0; buf[o + 2] = 0; buf[o + 3] = 0;
      } else {
        buf[o] = c[0]; buf[o + 1] = c[1]; buf[o + 2] = c[2]; buf[o + 3] = 255;
      }
    }
  }
  await sharp(buf, { raw: { width: W, height: H, channels: 4 } })
    .resize(W * scale, H * scale, { kernel: 'nearest' })
    .png()
    .toFile(outPath);
}

await render(slimeFrame, slimePalette, path.join(OUT, 'slime-baby-idle-16x.png'), 16);
await render(slimeFrame, slimePalette, path.join(OUT, 'slime-baby-idle-32x.png'), 32);
await render(slimeFrame, slimePalette, path.join(OUT, 'slime-baby-idle-64x.png'), 64);
await render(octopusFrame, octopusPalette, path.join(OUT, 'octopus-baby-idle-16x.png'), 16);
await render(octopusFrame, octopusPalette, path.join(OUT, 'octopus-baby-idle-32x.png'), 32);
await render(octopusFrame, octopusPalette, path.join(OUT, 'octopus-baby-idle-64x.png'), 64);

console.log('Wrote 4 reference PNGs to', OUT);
