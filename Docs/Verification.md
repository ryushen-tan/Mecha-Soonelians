# Gameplay verification

Verified on October 24, 2026. These passed with no skips: 13 native unit/integration tests and three Simulator UI tests, using the cached full-body human `FEAE1A47…` and a local Next.js server on port 3099. Also passing: 25 server tests, 22 viewer tests and production Next.js integration. Rally and the legacy scanner built for Simulator. These results do not include physical-device AR/LiDAR testing.

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

## Editor and gameplay behaviour under test

This section describes the current editor. Earlier iterations (automatic wall attachment, arrow buttons, Move/Height joysticks) were removed and are no longer tested.

- **Two modes.** **Position & pose** owns body placement, including **Against wall**. **Lock** switches to **Paint** and keeps the chosen transform. Returning to placement keeps the paint. Joint and pose edits are rejected while locked.
- **Direct manipulation.** Tap the person to select it. A lime bounding outline and X/Y/Z handles appear. **Move** drags along the supporting surface, **Rotate** exposes all three rings and **Size** resizes uniformly (15%–150%). Dragging the background orbits. A two-finger gesture that starts on the body cancels the drag and zooms or pans the camera. Placement lock and hunting hide the handles.
- **Surface constraint.** The viewer measures an oriented collider from the visible posed, skinned body, raycasts the supporting face and slides in small collision-checked steps. Walls, floors and furniture block movement; decorations do not. The whole footprint must fit, including at door openings and floor edges. A pose, size or turn change that would intersect geometry restores the last safe shape. Saved bodies and clones are re-fitted on load. **To floor** picks a clear floor rather than detaching into free space.
- **Painting.** The paint view shows real room geometry, using surface colors rather than photo textures. A closer camera paints finer world-space marks. Pinching never leaves paint.
- **Emergency eject.** The tested path runs from the native hider through the authenticated Next.js action and the server-chosen floor spot, then the snapshot offset, to the native seeker. The test checks that bounds match on all three, that paint and pose are unchanged, and that the relocated triangles tag for 500 points. Server tests cover authentication, one use per round, phase/role/found restrictions, rejection of client-supplied positions, blocked and undersized rooms, transformed RoomPlan floors and clone movement.

Viewer tests cover pointer-to-surface dragging, transform math, uniform resizing, selection and cancellation, thin-wall tunneling, sliding along furniture, doorway clearance, transformed RoomPlan geometry and wall-backed paint framing. Real-human native tests drive canvas pointer events: select and drag, cancel, pinch, pick the actual rotation rings, resize, lock and save. They also open an intersecting saved placement and check for a 6 mm support gap with no collisions. The Simulator UI flow taps and drags the person, switches transform tools, uses both Pose wheel pages, paints, pinches, saves and reopens. Evidence such as `surface-constraints.json` and `surface-constrained-human.png` is written alongside the other native render evidence. These checks cover the supplied room geometry, not unscanned physical obstacles.

## Reproduce

1. Install a real generated rigged human in the Simulator via the app's Tripo flow, or reuse an existing saved character. Tests copy its original mesh to temporary assets and remove those temporary assets afterward.
2. `npm test --prefix server`
3. `npm test --prefix Tools/CharacterViewer`
4. `npm run build --prefix server && npm run test:integration --prefix server`
5. For the native multiplayer test, start an isolated instance: `cd server && npx next start --hostname 127.0.0.1 --port 3099`.
6. Run the Rally scheme's native unit/UI tests in Xcode. Real-human tests explicitly skip if no generated human is present; the native multiplayer test skips if the isolated server is absent.

Native render evidence is written under the app's `Documents/Verification/character-gameplay/`. Xcode's test result includes wheel/reopen screenshots. Camera depth, real RoomPlan capture, physical AR alignment/occlusion and a multi-iPhone session still require hardware tests. Simulator builds and virtual-room play do not establish those capabilities.
