# Real iPhone LiDAR test fixture

Downloaded from [Galaxywalk/iLiDAR](https://github.com/Galaxywalk/iLiDAR/tree/66cd476170eae6f023f0a585d6e89f2a3e5c2bcf/Server/example_data), which publishes these files as its RGB/depth example pair. The upstream MIT license is included in `LICENSE.txt`.

## Files

- `rgb.jpg`: original color image. The scene is a room with furniture, with no person.
- `depth-float16.bin`: original numeric depth buffer, 320 x 240, little-endian Float16, row-major, 153,600 bytes. Dimensions and encoding follow the upstream `Server/read_depth_data.py`.
- `depth-preview.png`: generated grayscale visualization. Nearer points are brighter; black is invalid. This is not metric depth and must not be used for measurements.
- `metadata.json`: format, provenance, measured range, and checksums.
- `prepare.py`: validates the downloaded buffers and regenerates the preview and metadata; requires NumPy and Pillow.

## Use

Use the JPG and raw depth buffer to exercise image loading, depth decoding, and applying the same normalized crop rectangle to differently sized buffers. Keep the original pixel orientation for both images. The upstream pair has no timestamps or camera calibration, so exact synchronization and registration are not independently verified; do not use it as a calibrated measurement reference.

This is a loose RGB/depth fixture, not a HEIC containing `AVDepthData`. It does not test HEIC auxiliary-data extraction, live camera capture, or person segmentation. A full-body capture is still needed for player cutout validation. These fixtures are not bundled into the app automatically.

Regenerate from the repository root:

```sh
python3 TestFixtures/LiDAR/room/prepare.py
```
