from pathlib import Path
import hashlib
import json
import sys
import tarfile

import numpy as np
from PIL import Image


directory = Path(__file__).resolve().parent
rgb_timestamp = 1341846227.622081
rgb_member = "rgbd_dataset_freiburg3_walking_static/rgb/1341846227.622081.png"
with tarfile.open(sys.argv[1], "r:gz") as archive:
    depth_members = [member for member in archive.getmembers() if "/depth/" in member.name and member.name.endswith(".png")]
    depth_member = min(depth_members, key=lambda member: abs(float(Path(member.name).stem) - rgb_timestamp))
    depth_timestamp = float(Path(depth_member.name).stem)
    difference = abs(depth_timestamp - rgb_timestamp)
    if difference > 0.03:
        raise ValueError("No depth frame within 30 ms of selected RGB frame")
    for member, filename in [(rgb_member, "human-rgb.png"), (depth_member, "human-depth-uint16.png")]:
        directory.joinpath(filename).write_bytes(archive.extractfile(member).read())

with Image.open(directory / "human-depth-uint16.png") as depth_image:
    depth = np.asarray(depth_image).astype(np.float32) / 5000
with Image.open(directory / "human-rgb.png") as rgb_image:
    if depth.shape != (rgb_image.height, rgb_image.width):
        raise ValueError("RGB and depth dimensions differ")
depth.astype("<f4").tofile(directory / "human-depth-float32.bin")
valid = np.isfinite(depth) & (depth > 0)
minimum, maximum = float(depth[valid].min()), float(depth[valid].max())
preview = np.zeros(depth.shape, dtype=np.uint8)
preview[valid] = (1 + 254 * (1 - (depth[valid] - minimum) / (maximum - minimum))).astype(np.uint8)
Image.fromarray(preview).save(directory / "human-depth-preview.png")
metadata = {
    "dataset": "TUM RGB-D benchmark",
    "sequence": "freiburg3_walking_static",
    "source": "https://cvg.cit.tum.de/data/datasets/rgbd-dataset",
    "archive": "https://cvg.cit.tum.de/rgbd/dataset/freiburg3/rgbd_dataset_freiburg3_walking_static.tgz",
    "license": "CC BY 4.0",
    "license_url": "https://creativecommons.org/licenses/by/4.0/",
    "attribution": "TUM RGB-D benchmark; J. Sturm, N. Engelhard, F. Endres, W. Burgard, D. Cremers (IROS 2012)",
    "sensor": "Kinect RGB-D (not iPhone LiDAR)",
    "synthetic": False,
    "rgb_member": rgb_member,
    "depth_member": depth_member.name,
    "rgb_timestamp": rgb_timestamp,
    "depth_timestamp": depth_timestamp,
    "timestamp_difference_seconds": difference,
    "width": int(depth.shape[1]),
    "height": int(depth.shape[0]),
    "raw_png": "uint16; divide by 5000 for meters; zero means missing measurement",
    "float_buffer": "little-endian Float32 meters, row-major, zero means missing measurement",
    "registration": "Registered to RGB by the source dataset; nearest timestamp pairing",
    "rgb_intrinsics": {"fx": 535.4, "fy": 539.2, "cx": 320.1, "cy": 247.6},
    "depth_range_meters": [minimum, maximum],
    "valid_fraction": float(valid.mean()),
    "preview": "Visualization only; nearer is brighter; zero is invalid",
    "derived_assets": "Float32 conversion and depth visualization; cutouts and joints generated locally using Apple Vision",
    "sha256": {name: hashlib.sha256(directory.joinpath(name).read_bytes()).hexdigest() for name in ["human-rgb.png", "human-depth-uint16.png", "human-depth-float32.bin"]},
}
directory.joinpath("human-depth-metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
print(json.dumps(metadata, indent=2))
