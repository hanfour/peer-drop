# fal → PixelLab reference pipeline

> **TL;DR** — fal designs the *look* of a new pet (one clean reference image);
> PixelLab turns that reference into the 8-direction + walk/idle pixel sprite
> the bundle ships. Use fal for the creative front, PixelLab for the
> game-sprite back. This is the recommended "best approach" after evaluating
> fal's 2026 capabilities against PeerDrop's exact asset spec (2026-06-13).

## Why hybrid (and not fal end-to-end)

PeerDrop ships a strict sprite contract: **68×68 pixel-art**, **8 compass
directions**, **walk (8 frames) + idle (5 frames)**, transparent, the *same*
character across every frame and direction, atlas-packed by
`Scripts/build_atlas.py` and gated by `MainBundleAssetCoverageTests`.

- **PixelLab** is purpose-built for exactly this — native low-res pixel art,
  single-reference → 8-direction rotation, skeleton-based animation that keeps
  the character identical across frames. The existing
  `gen_pixellab_zip.py → normalize_pixellab.py → build_atlas.py` tail already
  produces bundle-ready, test-passing zips.
- **fal** (2026) has excellent base-art generation (Recraft V3, FLUX, Imagen4,
  nano-banana) and even general sprite-sheet tools — but those are *general*:
  high-res faux-pixel needing downscale, limited/3-direction coverage,
  uncontrolled frame counts, no guarantee of cross-direction identity. They'd
  bypass the battle-tested normalize/atlas/coverage tooling.

So fal does what it's best at (designing the breed) and feeds PixelLab, which
does what *it's* best at (turning one reference into the exact sprite spec).

```
[breed spec: species/variant/palette/descriptors]
      │
      ▼  Scripts/gen_fal_reference.py   (fal — Recraft V3 pixel_art + palette colors, optional BRIA bg-removal)
  reference.png
      │
      ▼  Scripts/gen_pixellab_zip.py    (PixelLab — 8-dir rotate + walk/idle skeleton animation)
  raw v2.0 zip
      │
      ▼  Scripts/normalize-pixellab-zip.sh → build_atlas.py
  bundled v5 zip  →  PeerDrop/Resources/Pets/  +  expectedV5Coverage whitelist
```

## Running the fal step

```bash
pip install fal-client pillow
export FAL_KEY=...        # https://fal.ai/dashboard/keys

python3 Scripts/gen_fal_reference.py \
  --species cat --variant russianblue \
  --descriptors "fluffy, big round eyes, sitting" \
  --palette "#5b6b78,#8a9aa8,#c9d4dc" \
  --out docs/pet-design/ai-brief/raw-output/cat-russianblue-ref.png \
  --pixel-size 128 --remove-bg
```

- `--palette` (genome hex colors) is passed to Recraft's `colors` field so the
  generation is biased toward the pet's palette.
- `--pixel-size N` nearest-neighbour downscales the high-res Recraft output to a
  crisp N×N reference. `--remove-bg` runs BRIA background removal for a clean
  transparent seed.
- Default model `fal-ai/recraft/v3/text-to-image`, style
  `digital_illustration/pixel_art` — both overridable (`--style`, and
  `FalReferenceClient(model=...)` for a different fal model).

Then hand `reference.png` to the PixelLab step exactly as today.

## Verification status

`Scripts/test_gen_fal_reference.py` covers the pure helpers (prompt assembly,
palette→RGB) and the orchestration (file write, style/colors passed through,
bg-removal gating, missing-key error) with an injected fake client — no
FAL_KEY / network / fal-client / Pillow required. **The actual image quality
from fal can only be judged with a real FAL_KEY + a visual review** — run the
command above against a couple of breeds and eyeball the references before
committing to a batch.
