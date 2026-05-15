#!/usr/bin/env python3
"""Python client for the PixelLab AI HTTP API.

Wraps the endpoints relevant to PeerDrop's v5 mass-gen workstream:
  - POST /rotate                    — generate a directional view from a reference
  - POST /animate-with-skeleton     — render an animation frame from a skeleton pose
  - POST /estimate-skeleton         — detect bone structure from an image
  - POST /create-image-pixflux      — text-to-pixel-art (not used by mass-gen but in for completeness)

Auth: set `PIXELLAB_API_KEY` in the environment. The client sends it as
`Authorization: Bearer <key>` — adjust `auth_header()` if your account
issues a different scheme.

Base URL defaults to `https://api.pixellab.ai/v1`; override via
`PIXELLAB_API_URL` if PixelLab promotes v2 to default before this
script catches up.

Cost model (verify against your actual invoice — these are 2026-05-14
WebFetched estimates):
  - 64×64 generation: ~$0.0072–0.0079
  - 128×128 generation: ~$0.0080–0.0085
  - Background transparency adds a small premium

The wrappers return `bytes` for image responses (decoded base64) and
`dict` for JSON responses. Retry logic backs off exponentially on 5xx
errors only — 4xx errors surface immediately so the operator can fix
the request (bad keypoints / image size out of range / etc.).
"""

import base64
import json
import os
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from typing import Any, Optional


DEFAULT_BASE_URL = "https://api.pixellab.ai/v1"
DEFAULT_TIMEOUT_SECONDS = 180
DEFAULT_MAX_RETRIES = 3
DEFAULT_BACKOFF_BASE_SECONDS = 1.0


@dataclass
class PixelLabError(Exception):
    status: int
    detail: str = ""

    def __str__(self) -> str:
        return f"PixelLab HTTP {self.status}: {self.detail}"


@dataclass
class Keypoint:
    """One joint in a skeleton frame. `label` matches PixelLab's vocabulary
    (e.g. "head", "left_hip", "tail_tip"); positions are in image pixels
    where (0,0) is top-left."""
    x: float
    y: float
    label: str
    z_index: int = 0

    def as_payload(self) -> dict[str, Any]:
        return {"x": self.x, "y": self.y, "label": self.label, "z_index": self.z_index}


@dataclass
class PixelLabClient:
    api_key: Optional[str] = None
    base_url: str = DEFAULT_BASE_URL
    timeout_seconds: int = DEFAULT_TIMEOUT_SECONDS
    max_retries: int = DEFAULT_MAX_RETRIES
    backoff_base_seconds: float = DEFAULT_BACKOFF_BASE_SECONDS

    def __post_init__(self) -> None:
        if self.api_key is None:
            self.api_key = os.environ.get("PIXELLAB_API_KEY")
        env_url = os.environ.get("PIXELLAB_API_URL")
        if env_url:
            self.base_url = env_url
        if not self.api_key:
            raise PixelLabError(
                status=0,
                detail="No API key: set PIXELLAB_API_KEY env var or pass api_key= to PixelLabClient",
            )

    # ─── Auth ────────────────────────────────────────────────────────────

    def auth_header(self) -> dict[str, str]:
        """Build the auth header. PixelLab documents Bearer auth on its
        landing page; adjust here if your account uses a different
        scheme (some self-serve accounts get `X-API-Key`)."""
        return {"Authorization": f"Bearer {self.api_key}"}

    # ─── Endpoint wrappers ───────────────────────────────────────────────

    def rotate(
        self,
        *,
        image_bytes: bytes,
        image_size: tuple[int, int],
        from_direction: str,
        to_direction: str,
        from_view: str = "side",
        to_view: str = "side",
        image_guidance_scale: float = 3.0,
        seed: Optional[int] = None,
    ) -> bytes:
        """Generate one rotated view from a reference image. Returns the
        PNG bytes of the result. Direction strings use PixelLab's compass
        vocabulary: south / south-east / east / north-east / north /
        north-west / west / south-west."""
        body: dict[str, Any] = {
            "image_size": {"width": image_size[0], "height": image_size[1]},
            "from_image": _b64encode_png(image_bytes),
            "from_direction": from_direction,
            "to_direction": to_direction,
            "from_view": from_view,
            "to_view": to_view,
            "image_guidance_scale": image_guidance_scale,
        }
        if seed is not None:
            body["seed"] = seed
        result = self._post_json("/rotate", body)
        return _decode_image_response(result)

    def animate_with_skeleton(
        self,
        *,
        reference_image_bytes: bytes,
        image_size: tuple[int, int],
        skeleton_frames: list[list[Keypoint]],
        view: str = "side",
        direction: str = "east",
        guidance_scale: float = 4.0,
        seed: Optional[int] = None,
    ) -> list[bytes]:
        """Render multiple animation frames in one API call.
        `skeleton_frames` is a list of frames where each frame is a list
        of Keypoints. PixelLab requires minimum 3 frames per batch.
        Returns a list of PNG bytes, one per frame, in the same order.
        The reference image is resized to image_size — PixelLab's
        internal tensor pipeline requires them to match."""
        body: dict[str, Any] = {
            "image_size": {"width": image_size[0], "height": image_size[1]},
            "reference_image": _b64encode_png(_resize_png(reference_image_bytes, image_size)),
            "skeleton_keypoints": [
                [kp.as_payload() for kp in frame] for frame in skeleton_frames
            ],
            "view": view,
            "direction": direction,
            "guidance_scale": guidance_scale,
        }
        if seed is not None:
            body["seed"] = seed
        result = self._post_json("/animate-with-skeleton", body)
        # Response shape: {"usage": {...}, "images": [{...base64image...}, ...]}
        images = result.get("images")
        if not isinstance(images, list):
            raise PixelLabError(
                status=0,
                detail=f"animate-with-skeleton expected `images` array, got {sorted(result.keys())}",
            )
        return [base64.b64decode(img["base64"]) for img in images]

    def estimate_skeleton(
        self,
        *,
        image_bytes: bytes,
        image_size: tuple[int, int],
    ) -> list[Keypoint]:
        """Detect bone structure from an image. Returns the estimated
        keypoints as `Keypoint` objects suitable for feeding back into
        `animate_with_skeleton`."""
        body: dict[str, Any] = {
            "image_size": {"width": image_size[0], "height": image_size[1]},
            "image": _b64encode_png(image_bytes),
        }
        result = self._post_json("/estimate-skeleton", body)
        raw_kps = result.get("keypoints") or result.get("skeleton_keypoints") or []
        return [
            Keypoint(
                x=float(kp["x"]),
                y=float(kp["y"]),
                label=str(kp.get("label", "")),
                z_index=int(kp.get("z_index", 0)),
            )
            for kp in raw_kps
        ]

    def create_image_pixflux(
        self,
        *,
        prompt: str,
        image_size: tuple[int, int],
        negative_prompt: str = "",
        guidance_scale: float = 7.0,
        seed: Optional[int] = None,
    ) -> bytes:
        """Pure text-to-pixel-art. Not used by mass-gen but exposed here
        so the client is a complete reference."""
        body: dict[str, Any] = {
            "image_size": {"width": image_size[0], "height": image_size[1]},
            "description": prompt,
            "guidance_scale": guidance_scale,
        }
        if negative_prompt:
            body["negative_description"] = negative_prompt
        if seed is not None:
            body["seed"] = seed
        result = self._post_json("/create-image-pixflux", body)
        return _decode_image_response(result)

    # ─── HTTP plumbing ──────────────────────────────────────────────────

    def _post_json(self, path: str, body: dict[str, Any]) -> dict[str, Any]:
        url = self.base_url.rstrip("/") + path
        encoded = json.dumps(body).encode("utf-8")
        headers = {"Content-Type": "application/json", **self.auth_header()}

        last_error: Optional[Exception] = None
        for attempt in range(self.max_retries):
            req = urllib.request.Request(url, data=encoded, headers=headers, method="POST")
            try:
                with urllib.request.urlopen(req, timeout=self.timeout_seconds) as resp:
                    payload = resp.read().decode("utf-8")
                    return json.loads(payload)
            except urllib.error.HTTPError as e:
                detail = ""
                try:
                    detail = e.read().decode("utf-8")
                except Exception:
                    pass
                # 5xx = server-side transient, exponential backoff.
                # 429 = rate-limited, longer backoff (PixelLab's
                # documented retry-after is up to 60s).
                is_retryable = (
                    (500 <= e.code < 600) or e.code == 429
                ) and attempt < self.max_retries - 1
                if is_retryable:
                    sleep = self.backoff_base_seconds * (2 ** attempt)
                    if e.code == 429:
                        sleep = max(sleep, 30.0 * (attempt + 1))  # 30s, 60s, 90s
                    last_error = e
                    time.sleep(sleep)
                    continue
                raise PixelLabError(status=e.code, detail=detail) from e
            except (urllib.error.URLError, TimeoutError) as e:
                if attempt < self.max_retries - 1:
                    last_error = e
                    time.sleep(self.backoff_base_seconds * (2 ** attempt))
                    continue
                raise PixelLabError(status=0, detail=f"Network error: {e}") from e
        # Should not reach here; the loop either returns or raises.
        raise PixelLabError(status=0, detail=f"Exhausted retries: {last_error}")


# ─── Helpers ────────────────────────────────────────────────────────────


def _resize_png(image_bytes: bytes, target_size: tuple[int, int]) -> bytes:
    """Resize a PNG to target_size (width, height) preserving alpha.
    PixelLab's animate pipeline expects reference_image dimensions to
    exactly match the declared image_size."""
    import io
    from PIL import Image
    img = Image.open(io.BytesIO(image_bytes)).convert("RGBA")
    if img.size == target_size:
        return image_bytes
    resized = img.resize(target_size, Image.NEAREST)
    buf = io.BytesIO()
    resized.save(buf, format="PNG")
    return buf.getvalue()


def _b64encode_png(image_bytes: bytes) -> dict[str, str]:
    """PixelLab API wraps image payloads in a `Base64Image` object
    (per OpenAPI schema): `{"type": "base64", "base64": "<encoded>"}`.
    Standard alphabet, no URL-safe transforms, no data: prefix."""
    return {
        "type": "base64",
        "base64": base64.b64encode(image_bytes).decode("ascii"),
    }


def _decode_image_response(result: dict[str, Any]) -> bytes:
    """PixelLab image-producing endpoints return one of these shapes
    (per OpenAPI schema):
      - {"image": {"type": "base64", "base64": "<b64>"}}  (pixflux, rotate)
      - {"images": [{"type": "base64", "base64": "<b64>"}]} (animate-with-skeleton, array)
      - {"url": "<download-url>"}  (large-payload fallback, if any)
    Returns the decoded PNG bytes of the first image."""
    if isinstance(result.get("image"), dict) and "base64" in result["image"]:
        return base64.b64decode(result["image"]["base64"])
    images = result.get("images")
    if isinstance(images, list) and images and isinstance(images[0], dict) and "base64" in images[0]:
        return base64.b64decode(images[0]["base64"])
    if "url" in result:
        with urllib.request.urlopen(result["url"]) as resp:
            return resp.read()
    raise PixelLabError(
        status=0,
        detail=f"Unexpected image response shape: keys={sorted(result.keys())}",
    )


# ─── CLI smoke test ─────────────────────────────────────────────────────


if __name__ == "__main__":
    import argparse
    import sys
    parser = argparse.ArgumentParser(description="PixelLab API client smoke test.")
    parser.add_argument(
        "--smoke",
        action="store_true",
        help="Initialize the client (auth header check only — no API call).",
    )
    args = parser.parse_args()
    if args.smoke:
        try:
            c = PixelLabClient()
            print(f"PixelLabClient ok: base_url={c.base_url}")
            print(f"  Auth header: {list(c.auth_header().keys())} (key length: {len(c.api_key or '')} chars)")
        except PixelLabError as e:
            print(f"PixelLabClient init failed: {e}", file=sys.stderr)
            raise SystemExit(1)
    else:
        parser.print_help()
