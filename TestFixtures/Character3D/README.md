# Synthetic 3D rig fixture

`test-rig.glb` is a two-bone, skin-weighted cylinder generated entirely by
`Tools/CharacterViewer/make-test-rig.mjs`. It is not a person, a scan, or a Tripo
output. It is bundled only into the native unit-test target to verify GLB
loading, skeleton discovery, joint rotation, and export without spending credits.

Regenerate with `node Tools/CharacterViewer/make-test-rig.mjs` after installing
the dependencies in that directory.
