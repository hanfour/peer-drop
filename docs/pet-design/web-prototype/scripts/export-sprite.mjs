#!/usr/bin/env node
// Extract sprite + palette data from the Swift source files into JSON
// for the web prototype to consume.
//
// Inputs (relative to repo root):
//   PeerDrop/Pet/Sprites/CatSpriteData.swift
//   PeerDrop/Pet/Renderer/PetPalettes.swift
//
// Outputs (relative to web-prototype root):
//   public/data/cat.json       — meta + baby/child action frames
//   public/data/palettes.json  — { default: { "1": "#hex", ... }, all: [...] }
//
// Strategy: parse `private static let <name>Frames: [[[UInt8]]] = [ ... ]`
// blocks by bracket depth. Strip Swift line comments + trailing commas, then
// JSON.parse the array literal. Only export the 6 actions needed for v0.

import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, '../../../..');
const outDir = path.resolve(__dirname, '../public/data');

const ACTIONS = ['idle', 'walk', 'happy', 'sleep', 'tapReact', 'scared'];
// Swift uses `<action>Frames` for baby and `child<Action>Frames` for child.
// Map JSON key -> swift identifier base.
const ACTION_KEY_MAP = {
  idle: 'idle',
  walking: 'walk',
  happy: 'happy',
  sleeping: 'sleep',
  tapReact: 'tapReact',
  scared: 'scared',
};

/**
 * Find a block beginning with `<prefix>` and capture text from the first
 * `[` after the `=` to its matching `]`. Returns the array literal (still
 * Swift syntax) or null.
 */
function extractArrayLiteral(source, declaration) {
  const idx = source.indexOf(declaration);
  if (idx < 0) return null;
  // Find the first '=' after the declaration (skipping the type which may
  // itself contain `[[[UInt8]]]`), then the first '[' after that.
  const eq = source.indexOf('=', idx + declaration.length);
  if (eq < 0) return null;
  let i = source.indexOf('[', eq);
  if (i < 0) return null;
  let depth = 0;
  const start = i;
  for (; i < source.length; i++) {
    const ch = source[i];
    if (ch === '[') depth++;
    else if (ch === ']') {
      depth--;
      if (depth === 0) {
        return source.slice(start, i + 1);
      }
    }
  }
  return null;
}

/**
 * Convert a Swift-syntax array of int arrays (with comments / trailing
 * commas / whitespace) into a JS value via JSON.parse.
 */
function swiftArrayToJSON(literal) {
  // 1) Strip // line comments
  let s = literal.replace(/\/\/[^\n]*/g, '');
  // 2) Strip /* */ block comments (rare here)
  s = s.replace(/\/\*[\s\S]*?\*\//g, '');
  // 3) Remove trailing commas before closing brackets
  s = s.replace(/,(\s*[\]\}])/g, '$1');
  // 4) Collapse whitespace (optional, helps debugging)
  s = s.replace(/\s+/g, ' ').trim();
  return JSON.parse(s);
}

function parseFrames(swiftSrc, identifier) {
  const decl = `let ${identifier}: [[[UInt8]]]`;
  const literal = extractArrayLiteral(swiftSrc, decl);
  if (!literal) {
    throw new Error(`Could not find declaration for ${identifier}`);
  }
  const frames = swiftArrayToJSON(literal);
  // Sanity check: each frame is 16 rows of 16 ints
  for (let f = 0; f < frames.length; f++) {
    const frame = frames[f];
    if (!Array.isArray(frame) || frame.length !== 16) {
      throw new Error(`${identifier} frame ${f} not 16 rows (got ${frame?.length})`);
    }
    for (let r = 0; r < 16; r++) {
      if (!Array.isArray(frame[r]) || frame[r].length !== 16) {
        throw new Error(`${identifier} frame ${f} row ${r} not 16 cols (got ${frame[r]?.length})`);
      }
    }
  }
  return frames;
}

function capitalize(str) {
  return str.charAt(0).toUpperCase() + str.slice(1);
}

// ---------------------------------------------------------------------------
// 1. Cat sprite
// ---------------------------------------------------------------------------
const catSrcPath = path.join(repoRoot, 'PeerDrop/Pet/Sprites/CatSpriteData.swift');
const catSrc = fs.readFileSync(catSrcPath, 'utf8');

const baby = {};
const child = {};

for (const [jsonKey, swiftBase] of Object.entries(ACTION_KEY_MAP)) {
  const babyId = `${swiftBase}Frames`;
  const childId = `child${capitalize(swiftBase)}Frames`;
  baby[jsonKey] = parseFrames(catSrc, babyId);
  child[jsonKey] = parseFrames(catSrc, childId);
}

const catJSON = {
  meta: { groundY: 14, eyeAnchor: { x: 4, y: 5 } },
  baby,
  child,
};

// ---------------------------------------------------------------------------
// 2. Palettes
// ---------------------------------------------------------------------------
const palettesSrcPath = path.join(repoRoot, 'PeerDrop/Pet/Renderer/PetPalettes.swift');
const palettesSrc = fs.readFileSync(palettesSrcPath, 'utf8');

// Extract every ColorPalette(...) inside `static let all: [ColorPalette] = [ ... ]`.
const allLiteral = extractArrayLiteral(palettesSrc, 'let all: [ColorPalette]');
if (!allLiteral) throw new Error('Could not find PetPalettes.all');

// Find every ColorPalette(...) constructor by bracket-balancing parens
const paletteCtors = [];
{
  const re = /ColorPalette\s*\(/g;
  let m;
  while ((m = re.exec(allLiteral)) !== null) {
    let i = m.index + m[0].length;
    let depth = 1;
    const start = i;
    for (; i < allLiteral.length; i++) {
      const ch = allLiteral[i];
      if (ch === '(') depth++;
      else if (ch === ')') {
        depth--;
        if (depth === 0) {
          paletteCtors.push(allLiteral.slice(start, i));
          break;
        }
      }
    }
  }
}

// Each ctor body has six `slot: Color(red: 0xRR/255, green: 0xGG/255, blue: 0xBB/255)`.
const SLOT_NAMES = ['outline', 'primary', 'secondary', 'highlight', 'accent', 'pattern'];
const SLOT_TO_INDEX = { outline: 1, primary: 2, secondary: 3, highlight: 4, accent: 5, pattern: 6 };

function parsePaletteCtor(body) {
  const out = { 0: 'transparent' };
  for (const slot of SLOT_NAMES) {
    const re = new RegExp(
      `${slot}\\s*:\\s*Color\\s*\\(\\s*red\\s*:\\s*0x([0-9A-Fa-f]{2})\\s*/\\s*255\\s*,\\s*green\\s*:\\s*0x([0-9A-Fa-f]{2})\\s*/\\s*255\\s*,\\s*blue\\s*:\\s*0x([0-9A-Fa-f]{2})\\s*/\\s*255`
    );
    const m = body.match(re);
    if (!m) throw new Error(`Could not parse slot ${slot} in palette ctor: ${body.slice(0, 80)}...`);
    const [, r, g, b] = m;
    out[String(SLOT_TO_INDEX[slot])] = `#${r.toUpperCase()}${g.toUpperCase()}${b.toUpperCase()}`;
  }
  return out;
}

const allPalettes = paletteCtors.map(parsePaletteCtor);
const palettesJSON = {
  default: allPalettes[0],
  all: allPalettes,
};

// ---------------------------------------------------------------------------
// 3. Write output
// ---------------------------------------------------------------------------
fs.mkdirSync(outDir, { recursive: true });
fs.writeFileSync(path.join(outDir, 'cat.json'), JSON.stringify(catJSON) + '\n');
fs.writeFileSync(path.join(outDir, 'palettes.json'), JSON.stringify(palettesJSON, null, 2) + '\n');

// ---------------------------------------------------------------------------
// 4. Summary
// ---------------------------------------------------------------------------
const summary = Object.entries(baby)
  .map(([k, v]) => `${k}=${v.length}`)
  .join(', ');
console.log(`Wrote ${path.relative(process.cwd(), path.join(outDir, 'cat.json'))}`);
console.log(`  baby frames: ${summary}`);
console.log(`  child frames: ${Object.entries(child).map(([k, v]) => `${k}=${v.length}`).join(', ')}`);
console.log(`Wrote ${path.relative(process.cwd(), path.join(outDir, 'palettes.json'))}`);
console.log(`  palettes: ${allPalettes.length}`);
