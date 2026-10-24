# Human RGB-depth fixture

Real people from the [TUM RGB-D benchmark](https://cvg.cit.tum.de/data/datasets/rgbd-dataset), sequence `freiburg3_walking_static`, licensed CC BY 4.0. Attribution and modification details are in `ATTRIBUTION.txt`, also bundled in the app.

This is a **Kinect depth capture, not iPhone LiDAR**. Two seated people make it useful for person selection, automatic masks, occlusion handling, and pose detection. Their overlapping limbs are a difficult rigging case; use a standing full-body capture with separated arms for cleaner deformation.

- `human-rgb.png`: original 640 x 480 RGB frame.
- `human-depth-uint16.png`: original registered depth; divide each sample by 5000 for meters. Zero means no measurement.
- `human-depth-float32.bin`: little-endian Float32 meters, row-major, no header; zero means no measurement.
- `human-depth-preview.png`: visual preview only, with closer surfaces brighter.
- `human-depth-metadata.json`: timestamps, source paths, calibration, checksums, depth range, and valid fraction.
- `human-analysis.json`, `human-*-mask.png`, `human-*-cutout.png`: locally generated Apple Vision results. The app attempts fresh analysis first, using these cached results only if the sample analysis throws an error; it labels that fallback visibly.

## Regenerate

Download the source archive to a temporary location, then run from the repository root:

```sh
python3 TestFixtures/HumanDepth/prepare.py /path/to/rgbd_dataset_freiburg3_walking_static.tgz
swiftc MechaSoonelians/Capture/HumanAnalyzer.swift Tools/AnalyzeHumanFixture.swift -o /tmp/mecha-analyze-human
/tmp/mecha-analyze-human TestFixtures/HumanDepth/human-rgb.png TestFixtures/HumanDepth
```

The Python conversion requires NumPy and Pillow. Native Vision analysis requires macOS. The source archive is not stored in the repository.

## Editor behavior

The app detects individuals, generates their alpha masks, and associates body joints with each mask. It creates an approximate **2D** rig by assigning cutout pixels to the nearest detected bone, then moving those pieces rigidly. Bone rotations preserve skeleton lengths and propagate through the limb hierarchy. Occluded joints are omitted rather than invented. Large changes can reveal gaps or overlaps; this is not a reconstructed or rigged 3D human.

Photo and depth views show the original capture. Pose changes deform only the cutout, not the source depth. Exports save the original photo, mask, unposed cutout, posed PNG, rig angles/joints, and original depth separately. Imported/captured encoded image data is retained as `original.image` to preserve any original auxiliary depth and calibration metadata.

On a physical device, Scan person detects people in the camera preview and enables Capture person when someone is visible. It requests depth photos on a supported capture configuration, with a labeled photo-only fallback. Live camera capture cannot be validated in Simulator.
