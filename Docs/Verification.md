# Gameplay verification

Verified on October 24, 2026: 10 native unit/integration tests plus three Simulator UI tests passed with no skips, as did 20 server tests, four viewer geometry tests and production Next.js integration. Rally built for Simulator and unsigned iOS devices; the legacy scanner built for Simulator. These results do not include physical-device AR/LiDAR testing.

## What was actually exercised

- Retrieved the requested video's English automatic captions and inspected its gameplay/pose-wheel footage. `GameplayMechanics.md` is a paraphrased implementation inventory; the full transcript/video remains in ignored local artifacts.
- Ran the actual bundled WebKit/Three.js renderer with real Tripo human meshes, not just a mock cylinder. Applied all 16 presets, checked finite transforms and unchanged world-space bone lengths, painted mesh triangles, undid/redid, turned front/back, froze two clones, saved GLB/paint/scene, and reopened without moving clones or losing paint.
- Exercised actual iPhone Simulator touch gestures: wheel selection, drawing on the human, undo/redo, saving and reopening. Fixed iOS 26's full-screen navigation swipe intercepting paint strokes.
- Used two native editors against a production Next.js instance: published a painted, skinned human with a clone, loaded it into the other renderer, aimed at actual human triangles, sent that ray through the native game model, and verified server scoring and the round winner.
- Tested all four round modes, phase/private-asset visibility, owner/clone elimination, Infection conversion, unique finds, Chicken targets, exposure scoring, cooldowns, whistles and wall/door occlusion. Geometry tests check transformed body axes, floor/wall contact, actual doorway triangles and hunter spawning.

## Mesh quality findings

The original seated TUM person has fused surfaces. Retargeting its arms can visibly pull its clothing/legs into large sheets. A rigged status alone was not sufficient: the first render check also exposed GLTF-loader bone-name sanitizing, which had prevented presets from moving.

A second standing frame from the same TUM sequence deformed substantially better, but its feet were outside the photo and remained missing in the generated result. The capture flow now warns before credit use when it cannot verify both hands/feet or sees foreshortened legs. The editor also measures surface-edge stretch after pose changes and warns on substantial distortion.

The complete full-body reference was [Jerma T pose.png](https://commons.wikimedia.org/wiki/File:Jerma_T_pose.png), attributed to Jerma, from the creator's freely reusable green-screen footage. The Commons description records permission for derivative use and links the source permission statement. Apple Vision removed the background locally; Tripo generated the textured mesh and Mixamo rig. This photograph has **no depth data**. The separately bundled TUM fixture remains the real registered RGB-D test input, not iPhone LiDAR.

The full-body source produced a 65-joint mesh with intact feet and markedly cleaner pose deformation. Final screenshots and stretch measurements are cached in `artifacts/gameplay-verification/`. These are evidence for this mesh, not a guarantee that every generated person will deform naturally. Two additional live mesh+rig jobs consumed 110 Tripo credits during this verification; automated tests do not submit paid jobs.

## Reproduce

1. Install a real generated rigged human in the Simulator via the app's Tripo flow, or reuse an existing saved character. Tests copy its original mesh to temporary assets and remove those temporary assets afterward.
2. `npm test --prefix server`
3. `npm test --prefix Tools/CharacterViewer`
4. `npm run build --prefix server && npm run test:integration --prefix server`
5. For the native multiplayer test, start an isolated instance: `cd server && npx next start --hostname 127.0.0.1 --port 3099`.
6. Run the Rally scheme's native unit/UI tests in Xcode. Real-human tests explicitly skip if no generated human is present; the native multiplayer test skips if the isolated server is absent.

Native render evidence is written under the app's `Documents/Verification/character-gameplay/`. Xcode's test result includes wheel/reopen screenshots. Camera depth, real RoomPlan capture, physical AR alignment/occlusion and a multi-iPhone session still require hardware tests. Simulator builds and virtual-room play do not establish those capabilities.
