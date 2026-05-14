#!/usr/bin/env python3
"""Unit tests for Scripts/pixellab_client.py.

Mocks at the urllib layer so no real API calls are made. Validates:
  - Auth header shape
  - Request body shape for each endpoint
  - Response decoding for each documented response shape
  - 5xx retry + backoff
  - 4xx surface-immediately behavior

Run from repo root:
    python3 -m unittest Scripts.test_pixellab_client
"""

import base64
import io
import json
import sys
import unittest
import urllib.error
from pathlib import Path
from unittest.mock import patch, MagicMock

sys.path.insert(0, str(Path(__file__).parent))

from pixellab_client import (  # noqa: E402
    DEFAULT_BASE_URL,
    Keypoint,
    PixelLabClient,
    PixelLabError,
    _b64encode_png,
    _decode_image_response,
)


FAKE_KEY = "pl-test-1234567890"
FAKE_PNG = b"\x89PNG\r\n\x1a\n" + b"fake-png-payload"


def make_response(payload: dict) -> MagicMock:
    """Build a fake urllib.request.urlopen context-manager response."""
    body = json.dumps(payload).encode("utf-8")
    resp = MagicMock()
    resp.read.return_value = body
    resp.__enter__ = lambda self: resp
    resp.__exit__ = lambda *a: False
    return resp


class AuthTests(unittest.TestCase):

    def test_init_from_env_var(self):
        with patch.dict("os.environ", {"PIXELLAB_API_KEY": FAKE_KEY}, clear=False):
            c = PixelLabClient()
            self.assertEqual(c.api_key, FAKE_KEY)
            self.assertEqual(c.base_url, DEFAULT_BASE_URL)

    def test_init_from_argument_overrides_env(self):
        with patch.dict("os.environ", {"PIXELLAB_API_KEY": "ignored"}, clear=False):
            c = PixelLabClient(api_key="explicit-key")
            self.assertEqual(c.api_key, "explicit-key")

    def test_init_without_key_raises(self):
        with patch.dict("os.environ", {}, clear=True):
            with self.assertRaises(PixelLabError) as cm:
                PixelLabClient()
            self.assertIn("PIXELLAB_API_KEY", str(cm.exception))

    def test_env_url_override(self):
        with patch.dict("os.environ",
                        {"PIXELLAB_API_KEY": FAKE_KEY,
                         "PIXELLAB_API_URL": "https://staging.pixellab.test/v3"},
                        clear=False):
            c = PixelLabClient()
            self.assertEqual(c.base_url, "https://staging.pixellab.test/v3")

    def test_auth_header_uses_bearer(self):
        c = PixelLabClient(api_key=FAKE_KEY)
        headers = c.auth_header()
        self.assertEqual(headers, {"Authorization": f"Bearer {FAKE_KEY}"})


class RotateEndpointTests(unittest.TestCase):

    def test_rotate_posts_expected_body_and_returns_decoded_image(self):
        c = PixelLabClient(api_key=FAKE_KEY)
        b64_out = base64.b64encode(b"output-png-bytes").decode("ascii")
        with patch("urllib.request.urlopen", return_value=make_response({"image": {"data": b64_out}})) as mock_open:
            result = c.rotate(
                image_bytes=FAKE_PNG,
                image_size=(68, 68),
                from_direction="south",
                to_direction="east",
            )
            self.assertEqual(result, b"output-png-bytes")

            # Confirm the actual outbound request body shape.
            req = mock_open.call_args[0][0]
            sent = json.loads(req.data.decode("utf-8"))
            self.assertEqual(sent["image_size"], {"width": 68, "height": 68})
            self.assertEqual(sent["from_direction"], "south")
            self.assertEqual(sent["to_direction"], "east")
            self.assertEqual(sent["from_view"], "side")
            self.assertEqual(sent["from_image"], _b64encode_png(FAKE_PNG))


class AnimateEndpointTests(unittest.TestCase):

    def test_animate_with_skeleton_serializes_keypoints(self):
        c = PixelLabClient(api_key=FAKE_KEY)
        kps = [
            Keypoint(x=10, y=20, label="head", z_index=2),
            Keypoint(x=30, y=40, label="hip"),
        ]
        b64_out = base64.b64encode(b"frame-bytes").decode("ascii")
        with patch("urllib.request.urlopen", return_value=make_response({"image_base64": b64_out})) as mock_open:
            result = c.animate_with_skeleton(
                reference_image_bytes=FAKE_PNG,
                image_size=(68, 68),
                skeleton_keypoints=kps,
                direction="south",
            )
            self.assertEqual(result, b"frame-bytes")
            req = mock_open.call_args[0][0]
            sent = json.loads(req.data.decode("utf-8"))
            self.assertEqual(
                sent["skeleton_keypoints"],
                [
                    {"x": 10, "y": 20, "label": "head", "z_index": 2},
                    {"x": 30, "y": 40, "label": "hip", "z_index": 0},
                ],
            )
            self.assertEqual(sent["direction"], "south")


class EstimateSkeletonTests(unittest.TestCase):

    def test_estimate_skeleton_parses_keypoint_list(self):
        c = PixelLabClient(api_key=FAKE_KEY)
        kp_response = {
            "keypoints": [
                {"x": 15.5, "y": 25.5, "label": "head", "z_index": 1},
                {"x": 35.0, "y": 45.0, "label": "hip"},
            ]
        }
        with patch("urllib.request.urlopen", return_value=make_response(kp_response)):
            result = c.estimate_skeleton(image_bytes=FAKE_PNG, image_size=(68, 68))
            self.assertEqual(len(result), 2)
            self.assertEqual(result[0].label, "head")
            self.assertEqual(result[0].x, 15.5)
            self.assertEqual(result[0].z_index, 1)
            self.assertEqual(result[1].z_index, 0)  # default when absent

    def test_estimate_skeleton_accepts_alternate_key_name(self):
        c = PixelLabClient(api_key=FAKE_KEY)
        with patch("urllib.request.urlopen",
                   return_value=make_response({"skeleton_keypoints": [{"x": 1, "y": 2, "label": "x"}]})):
            result = c.estimate_skeleton(image_bytes=FAKE_PNG, image_size=(68, 68))
            self.assertEqual(len(result), 1)


class RetryTests(unittest.TestCase):

    def test_5xx_retries_with_backoff(self):
        c = PixelLabClient(api_key=FAKE_KEY, max_retries=3, backoff_base_seconds=0.001)
        err = urllib.error.HTTPError(
            url="x", code=503, msg="Service Unavailable",
            hdrs=None, fp=io.BytesIO(b'{"error":"busy"}'))
        ok_resp = make_response({"image": {"data": base64.b64encode(b"win").decode("ascii")}})
        with patch("urllib.request.urlopen", side_effect=[err, err, ok_resp]) as mock_open:
            result = c.rotate(
                image_bytes=FAKE_PNG, image_size=(68, 68),
                from_direction="south", to_direction="east")
            self.assertEqual(result, b"win")
            self.assertEqual(mock_open.call_count, 3)

    def test_4xx_surfaces_immediately_without_retry(self):
        c = PixelLabClient(api_key=FAKE_KEY, max_retries=3, backoff_base_seconds=0.001)
        err = urllib.error.HTTPError(
            url="x", code=400, msg="Bad Request",
            hdrs=None, fp=io.BytesIO(b'{"error":"image_size out of range"}'))
        with patch("urllib.request.urlopen", side_effect=err) as mock_open:
            with self.assertRaises(PixelLabError) as cm:
                c.rotate(
                    image_bytes=FAKE_PNG, image_size=(999, 999),
                    from_direction="south", to_direction="east")
            self.assertEqual(cm.exception.status, 400)
            self.assertEqual(mock_open.call_count, 1)

    def test_5xx_exhausted_retries_raises(self):
        c = PixelLabClient(api_key=FAKE_KEY, max_retries=2, backoff_base_seconds=0.001)
        err = urllib.error.HTTPError(
            url="x", code=502, msg="Bad Gateway",
            hdrs=None, fp=io.BytesIO(b'gateway timeout'))
        with patch("urllib.request.urlopen", side_effect=err):
            with self.assertRaises(PixelLabError) as cm:
                c.rotate(
                    image_bytes=FAKE_PNG, image_size=(68, 68),
                    from_direction="south", to_direction="east")
            self.assertEqual(cm.exception.status, 502)


class ResponseDecodingTests(unittest.TestCase):

    def test_decodes_image_dict_shape(self):
        out = _decode_image_response({"image": {"data": base64.b64encode(b"abc").decode("ascii")}})
        self.assertEqual(out, b"abc")

    def test_decodes_image_base64_shape(self):
        out = _decode_image_response({"image_base64": base64.b64encode(b"xyz").decode("ascii")})
        self.assertEqual(out, b"xyz")

    def test_unknown_shape_raises(self):
        with self.assertRaises(PixelLabError):
            _decode_image_response({"weird": "shape"})


if __name__ == "__main__":
    unittest.main()
