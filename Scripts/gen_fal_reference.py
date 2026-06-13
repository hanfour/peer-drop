#!/usr/bin/env python3
"""Generate a clean pixel-art *reference* image of a PeerDrop pet via fal.ai
(Recraft V3), to SEED the existing PixelLab rotation + animation pipeline.

Why this exists
---------------
fal is where the pet base art is designed (and the team already has a fal
subscription). This automates that previously-manual "draw the new breed"
step so it becomes a reproducible script. fal does NOT replace PixelLab here:

    [breed spec] --(this script, fal)--> reference.png
                 --(gen_pixellab_zip.py, PixelLab)--> 8-dir + walk/idle raw zip
                 --(normalize_pixellab.py / build_atlas.py)--> bundled v5 zip

PixelLab still does the 8-direction rotation + skeleton walk/idle animation —
the part it is purpose-built for and that the bundle's atlas + coverage tests
expect. fal does the creative front (a single, style-consistent reference of
the new breed). Recraft V3's `digital_illustration/pixel_art` style + the
`colors` bias (fed from the genome palette) keeps the look on-brand.

Requirements
------------
    pip install fal-client pillow
    export FAL_KEY=...            # https://fal.ai/dashboard/keys

`fal-client` and Pillow are imported lazily so the pure helpers (and the unit
tests that inject a fake client) run with neither installed.

Usage
-----
    python3 Scripts/gen_fal_reference.py \
        --species cat --variant russianblue \
        --descriptors "fluffy, big eyes, sitting" \
        --palette "#5b6b78,#8a9aa8,#c9d4dc" \
        --out docs/pet-design/ai-brief/raw-output/cat-russianblue-ref.png \
        --pixel-size 128 --remove-bg

Then feed the reference into the PixelLab step (gen_pixellab_zip.py).
"""

from __future__ import annotations

import argparse
import dataclasses
import os
import sys
import urllib.request
from typing import Any, Optional, Protocol

# fal-ai/recraft/v3 text-to-image: prompt + image_size + style (StyleEnum) +
# colors ([{r,g,b}]). Result: {"images": [{"url", ...}]}. Verified against
# https://fal.ai/models/fal-ai/recraft/v3/text-to-image/api (2026-06).
DEFAULT_MODEL = "fal-ai/recraft/v3/text-to-image"
DEFAULT_STYLE = "digital_illustration/pixel_art"
DEFAULT_IMAGE_SIZE = "square_hd"
BRIA_REMOVE_BG_MODEL = "fal-ai/bria/background/remove"


class FalError(Exception):
    def __init__(self, detail: str, status: int = 0):
        self.detail = detail
        self.status = status
        super().__init__(detail)

    def __str__(self) -> str:
        return f"FalError(status={self.status}): {self.detail}"


# --- Pure helpers (no fal / no network — unit-tested directly) ---------------


def palette_to_colors(hex_colors: list[str]) -> list[dict[str, int]]:
    """Map `#RRGGBB` hex strings to Recraft `colors` RGB dicts so generation is
    biased toward the pet's genome palette. Invalid / empty entries are skipped.
    """
    out: list[dict[str, int]] = []
    for h in hex_colors:
        h = h.strip().lstrip("#")
        if len(h) != 6:
            continue
        try:
            r, g, b = int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)
        except ValueError:
            continue
        out.append({"r": r, "g": g, "b": b})
    return out


def build_prompt(species: str, variant: Optional[str], descriptors: str = "") -> str:
    """Compose a Recraft prompt for a single, centered, game-ready pet sprite.
    Mirrors the look the PixelLab references use: full-body, front-facing,
    plain background (so rotation/animation and bg-removal stay clean).
    """
    breed = f"{variant} {species}".strip() if variant else species
    extra = f", {descriptors.strip()}" if descriptors.strip() else ""
    return (
        f"a cute {breed} virtual pet character{extra}, full body, front view, "
        "centered, simple clean pixel art, 2D game sprite, flat plain background, "
        "no text, no shadow"
    )


# --- fal client --------------------------------------------------------------


class ReferenceClient(Protocol):
    """The surface generate_reference depends on. The real client hits fal;
    tests inject a fake. Keeps the orchestration testable without a FAL_KEY."""

    def generate(self, *, prompt: str, style: str, image_size: str,
                 colors: Optional[list[dict[str, int]]] = None) -> bytes: ...

    def remove_background(self, image_bytes: bytes) -> bytes: ...


@dataclasses.dataclass
class FalReferenceClient:
    model: str = DEFAULT_MODEL
    api_key: Optional[str] = None

    def __post_init__(self) -> None:
        if self.api_key is None:
            self.api_key = os.environ.get("FAL_KEY")
        if not self.api_key:
            raise FalError(
                "No API key: set FAL_KEY env var or pass api_key= to FalReferenceClient "
                "(get one at https://fal.ai/dashboard/keys)"
            )
        # fal-client reads FAL_KEY from the environment; make sure it's set even
        # when the key was passed explicitly.
        os.environ.setdefault("FAL_KEY", self.api_key)

    def _fal(self):  # lazy import so pure helpers / tests don't need the dep
        try:
            import fal_client  # type: ignore
        except ImportError as e:
            raise FalError("fal-client not installed — run `pip install fal-client`") from e
        return fal_client

    @staticmethod
    def _download(url: str) -> bytes:
        try:
            with urllib.request.urlopen(url, timeout=120) as resp:  # noqa: S310
                return resp.read()
        except Exception as e:  # noqa: BLE001
            raise FalError(f"Failed to download generated image: {e}") from e

    def generate(self, *, prompt: str, style: str, image_size: str,
                 colors: Optional[list[dict[str, int]]] = None) -> bytes:
        fal = self._fal()
        args: dict[str, Any] = {"prompt": prompt, "style": style, "image_size": image_size}
        if colors:
            args["colors"] = colors
        result = fal.subscribe(self.model, arguments=args)
        try:
            url = result["images"][0]["url"]
        except (KeyError, IndexError, TypeError) as e:
            raise FalError(f"Unexpected fal response shape: {result!r}") from e
        return self._download(url)

    def remove_background(self, image_bytes: bytes) -> bytes:
        fal = self._fal()
        import tempfile
        with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as f:
            f.write(image_bytes)
            tmp = f.name
        url = fal.upload_file(tmp)
        result = fal.subscribe(BRIA_REMOVE_BG_MODEL, arguments={"image_url": url})
        try:
            out_url = result["image"]["url"]
        except (KeyError, TypeError):
            out_url = result.get("images", [{}])[0].get("url")
        if not out_url:
            raise FalError(f"Unexpected BRIA response shape: {result!r}")
        return self._download(out_url)


# --- Optional pixel downscale (Pillow, lazy) ---------------------------------


def pixelate_png(image_bytes: bytes, target: int) -> bytes:
    """Nearest-neighbour downscale to `target`×`target` so the high-res Recraft
    output becomes a crisp low-res reference. Pillow imported lazily."""
    try:
        from PIL import Image  # type: ignore
    except ImportError as e:
        raise FalError("Pillow not installed — run `pip install pillow` (or omit --pixel-size)") from e
    import io
    img = Image.open(io.BytesIO(image_bytes)).convert("RGBA")
    img = img.resize((target, target), Image.NEAREST)
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


# --- Orchestration -----------------------------------------------------------


def generate_reference(
    *,
    species: str,
    variant: Optional[str],
    descriptors: str = "",
    palette_hex: Optional[list[str]] = None,
    client: ReferenceClient,
    output_path: str,
    style: str = DEFAULT_STYLE,
    image_size: str = DEFAULT_IMAGE_SIZE,
    pixel_size: Optional[int] = None,
    remove_bg: bool = False,
) -> str:
    """Generate one reference PNG and write it to `output_path`. Pure except for
    the injected `client` and the final file write — fully exercisable in tests."""
    prompt = build_prompt(species, variant, descriptors)
    colors = palette_to_colors(palette_hex or [])
    image = client.generate(prompt=prompt, style=style, image_size=image_size, colors=colors)
    if remove_bg:
        image = client.remove_background(image)
    if pixel_size:
        image = pixelate_png(image, pixel_size)
    os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)
    with open(output_path, "wb") as f:
        f.write(image)
    return output_path


def main(argv: Optional[list[str]] = None) -> int:
    p = argparse.ArgumentParser(description="Generate a pixel-art pet reference via fal (Recraft V3).")
    p.add_argument("--species", required=True)
    p.add_argument("--variant", default=None)
    p.add_argument("--descriptors", default="")
    p.add_argument("--palette", default="", help="comma-separated #RRGGBB hex colors")
    p.add_argument("--out", required=True)
    p.add_argument("--style", default=DEFAULT_STYLE)
    p.add_argument("--image-size", default=DEFAULT_IMAGE_SIZE)
    p.add_argument("--pixel-size", type=int, default=None, help="nearest-neighbour downscale to NxN")
    p.add_argument("--remove-bg", action="store_true", help="run BRIA background removal")
    args = p.parse_args(argv)

    palette = [c for c in args.palette.split(",") if c.strip()]
    try:
        client = FalReferenceClient()
        out = generate_reference(
            species=args.species, variant=args.variant, descriptors=args.descriptors,
            palette_hex=palette, client=client, output_path=args.out,
            style=args.style, image_size=args.image_size,
            pixel_size=args.pixel_size, remove_bg=args.remove_bg,
        )
    except FalError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1
    print(f"wrote {out}")
    print("next: feed it into the PixelLab step — Scripts/gen_pixellab_zip.py")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
