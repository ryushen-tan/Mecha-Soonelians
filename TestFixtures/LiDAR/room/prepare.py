from pathlib import Path
import hashlib
import json

import numpy as np
from PIL import Image


directory = Path(__file__).resolve().parent
raw = (directory / "depth-float16.bin").read_bytes()
if len(raw) != 320 * 240 * 2:
    raise ValueError("Expected a 320 x 240 Float16 depth buffer")
depth = np.frombuffer(raw, dtype="<f2").reshape(240, 320).astype(np.float32)
valid = np.isfinite(depth) & (depth > 0)
if not valid.any():
    raise ValueError("Depth buffer has no positive finite samples")
minimum = float(depth[valid].min())
maximum = float(depth[valid].max())
preview = np.zeros(depth.shape, dtype=np.uint8)
preview[valid] = np.rint(
    1 + 254 * (1 - (depth[valid] - minimum) / max(maximum - minimum, 1e-6))
).astype(np.uint8)
Image.fromarray(preview).save(directory / "depth-preview.png")
rgb = Image.open(directory / "rgb.jpg")
rgb.verify()
metadata = {
    "source": "https://github.com/Galaxywalk/iLiDAR",
    "source_commit": "66cd476170eae6f023f0a585d6e89f2a3e5c2bcf",
    "synthetic": False,
    "subject": "room, no people",
    "rgb_size": list(rgb.size),
    "depth_size": [320, 240],
    "depth_format": "little-endian IEEE 754 Float16, row-major, no header",
    "depth_units": "meters, based on upstream AVFoundation DepthFloat16 capture",
    "depth_range": [minimum, maximum],
    "valid_fraction": float(valid.mean()),
    "camera_calibration": None,
    "pairing": "Upstream example pair; capture timestamps not supplied",
    "preview": "8-bit visualization only; nearer is brighter; invalid is black",
    "sha256": {
        name: hashlib.sha256((directory / name).read_bytes()).hexdigest()
        for name in ["rgb.jpg", "depth-float16.bin"]
    },
}
(directory / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
print(json.dumps(metadata, indent=2))
