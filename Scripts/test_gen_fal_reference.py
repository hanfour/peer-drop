#!/usr/bin/env python3
"""Unit tests for Scripts/gen_fal_reference.py.

Injects a fake client so no FAL_KEY / network / fal-client / Pillow is needed
for the orchestration + pure-helper tests. Run from repo root:

    python3 -m unittest Scripts.test_gen_fal_reference
"""

import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from gen_fal_reference import (  # noqa: E402
    FalError,
    FalReferenceClient,
    build_prompt,
    generate_reference,
    palette_to_colors,
)


class FakeClient:
    """Implements the ReferenceClient surface; records calls."""

    def __init__(self, image: bytes = b"\x89PNG\r\n\x1a\nFAKE"):
        self.image = image
        self.generate_calls: list[dict] = []
        self.remove_bg_calls = 0

    def generate(self, *, prompt, style, image_size, colors=None) -> bytes:
        self.generate_calls.append(
            {"prompt": prompt, "style": style, "image_size": image_size, "colors": colors}
        )
        return self.image

    def remove_background(self, image_bytes: bytes) -> bytes:
        self.remove_bg_calls += 1
        return b"NOBG" + image_bytes


class PaletteToColorsTests(unittest.TestCase):
    def test_maps_hex_to_rgb(self):
        self.assertEqual(
            palette_to_colors(["#FF0000", "00FF00", "#0000ff"]),
            [{"r": 255, "g": 0, "b": 0}, {"r": 0, "g": 255, "b": 0}, {"r": 0, "g": 0, "b": 255}],
        )

    def test_skips_invalid_entries(self):
        self.assertEqual(palette_to_colors(["", "#abc", "nothex!", "#112233"]),
                         [{"r": 0x11, "g": 0x22, "b": 0x33}])


class BuildPromptTests(unittest.TestCase):
    def test_includes_species_variant_and_pixel_terms(self):
        prompt = build_prompt("cat", "russianblue", "fluffy")
        self.assertIn("russianblue cat", prompt)
        self.assertIn("fluffy", prompt)
        self.assertIn("pixel art", prompt)
        self.assertIn("plain background", prompt)

    def test_no_variant_uses_bare_species(self):
        self.assertIn("octopus", build_prompt("octopus", None))


class GenerateReferenceTests(unittest.TestCase):
    def test_writes_file_from_client_bytes(self):
        client = FakeClient(image=b"PNGDATA")
        with tempfile.TemporaryDirectory() as d:
            out = os.path.join(d, "nested", "ref.png")  # nested → dir auto-created
            generate_reference(species="dog", variant="husky",
                               palette_hex=["#112233"], client=client, output_path=out)
            self.assertTrue(os.path.exists(out))
            self.assertEqual(Path(out).read_bytes(), b"PNGDATA")

    def test_passes_pixel_art_style_and_palette_colors(self):
        client = FakeClient()
        with tempfile.TemporaryDirectory() as d:
            generate_reference(species="bear", variant="polar",
                               palette_hex=["#FFFFFF"], client=client,
                               output_path=os.path.join(d, "r.png"))
        call = client.generate_calls[0]
        self.assertEqual(call["style"], "digital_illustration/pixel_art")
        self.assertEqual(call["colors"], [{"r": 255, "g": 255, "b": 255}])

    def test_remove_bg_invoked_only_when_requested(self):
        client = FakeClient()
        with tempfile.TemporaryDirectory() as d:
            generate_reference(species="fox", variant=None, client=client,
                               output_path=os.path.join(d, "a.png"))
            self.assertEqual(client.remove_bg_calls, 0)
            generate_reference(species="fox", variant=None, client=client,
                               output_path=os.path.join(d, "b.png"), remove_bg=True)
            self.assertEqual(client.remove_bg_calls, 1)
            self.assertTrue(Path(os.path.join(d, "b.png")).read_bytes().startswith(b"NOBG"))


class ClientAuthTests(unittest.TestCase):
    def test_missing_api_key_raises_clear_error(self):
        saved = os.environ.pop("FAL_KEY", None)
        try:
            with self.assertRaises(FalError):
                FalReferenceClient(api_key=None)
        finally:
            if saved is not None:
                os.environ["FAL_KEY"] = saved

    def test_explicit_key_accepted(self):
        saved = os.environ.pop("FAL_KEY", None)
        try:
            c = FalReferenceClient(api_key="test-key")
            self.assertEqual(c.api_key, "test-key")
        finally:
            os.environ.pop("FAL_KEY", None)
            if saved is not None:
                os.environ["FAL_KEY"] = saved


if __name__ == "__main__":
    unittest.main()
