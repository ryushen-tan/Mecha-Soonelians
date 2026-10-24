# Mecha Soonelians gameplay reference

Reference: [Macro — MECCHA CHAMELEON … For Noobs](https://www.youtube.com/watch?v=yiLe2b5QuHw), 11:04. The English automatic captions and video were retrieved for implementation review; cached reference media stays in ignored `artifacts/reference-video/`.

This is a paraphrased mechanics inventory, not a reproduction of the transcript or the game's art.

| Video time | Observed mechanic | App interaction |
| --- | --- | --- |
| 0:52–1:23 | Hiders prepare a disguise; hunters search before time expires; characters attach to floors and walls. | Room placement, attachment and timed rounds. |
| 1:48–2:12 | Paint a character, choose colors on a wheel, sample scene colors, adjust metallic appearance and hide shadows. | Surface brush, color wheel, eyedropper, material sliders and shadow toggle. |
| 2:13–2:24 | Body shape and size change the disguise. | Character scale and selectable forms. |
| 2:27–2:33 | A radial menu selects poses that change the silhouette. Footage shows directional selection and release to confirm. | Press/drag/release pose wheel with multiple pages and tap alternatives. |
| 2:33–2:43 | Frozen copies keep a disguise; finding any copy also eliminates its owner. | Clone snapshots with shared owner identity. |
| 2:54–3:13 | Hunters wait during preparation. | Server-controlled preparation and hunt phases. |
| 3:24–3:38 | Hiders whistle; periodic automatic hints can be enabled. | Manual taunt and configurable timed hints. |
| 4:08–4:21 | Basic mode keeps fixed hunters and shows hiders their teammates' work. | Basic round rules. |
| 4:21–4:28 | Infection hides teammate positions; found hiders become hunters. | Infection role changes and visibility rules. |
| 4:33–4:49 | Double mode lets everyone hide and hunt, with points for finding disguises. | Individual disguise snapshots and score tracking. |
| 4:54–5:27 | Chicken race reveals one disguise at a time; finding it gives 500 points. | Sequential targets and explicit 500-point finds. |
| 5:49–6:22 | Different maps provide different hiding opportunities. | Saved RoomPlan geometry and a labeled practice room. |
| 7:47–7:58 | Own-body visibility through objects helps painting hidden areas. | Optional own-body-through-wall rendering, without revealing other players. |
| 9:08–9:31 | Visible hiding earns points, while survival still decides Basic rounds. | Server-estimated exposure points; survival/remaining targets decide Basic/Infection. |

The video is the source of the interaction model. Touch controls, the app's Rally styling, scanned rooms and captured humans are app-specific adaptations. A photograph cannot determine hidden body geometry, and a rig does not by itself guarantee lifelike skin deformation. Verification must inspect the real generated human, preserve bone lengths, constrain joint editing, test texture persistence and check exported skinning.

The video does not specify exact scoring rates, all pose angles, paint falloff or collision thresholds. This app uses 500-point finds, 10 exposure points/second, 16 original pose presets and an eight-sector/two-page wheel. RoomPlan boxes, touch walking and a practice scene replace downloadable game maps. Steam services and voice chat are outside this implementation; physical AR alignment is not verified by Simulator tests.

## App-specific editor and eject flow

The editor has two reversible modes: **Position & pose** for fitting and shrinking the body, then **Paint** after locking placement. Camera zoom/pan is independent of body transforms. A closer camera produces finer world-space brush marks, and two-finger navigation does not leave paint. Returning to placement preserves the painted texture.

Placement is constrained to a raycast-confirmed floor, wall or furniture face. Tap the person to select them, then drag the mesh or translation arrows along that face. Rotate exposes X/Y/Z rings; Size uniformly resizes the body using handles or an up/down body drag. Movement stops at obstacles, surface edges and wall openings; rotation and resizing are checked in small steps too. Attachment requires room for the entire posed body, not just a center-point hit. Pose changes re-fit a conservative oriented body collider measured from the visible skinned vertices; impossible changes restore the last safe shape. Old embedded placements and saved clones are re-fitted when opened. **To floor** replaces free detachment. **Pose** is the label for the radial pose selector. This protects against scanned geometry; unscanned real-world obstacles still require a new scan.

**Emergency eject** is a user-requested addition, not a claim about the reference video. An active hider gets one server-authorized use per round, with no location preview or undo. The server randomly chooses a different floor-supported position where the body and clones fit, but deliberately does not optimize visibility, color matching or concealment. Paint, pose, scale and scoring history stay unchanged; seekers' geometry and server tag bounds move together. Failed placement leaves the use available.
