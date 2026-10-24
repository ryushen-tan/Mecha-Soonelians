# Rally

Open `Rally.xcodeproj` for the integrated app: lobbies, RoomPlan scanning, and the human capture/pose Studio. `rally.yml` generates Rally. The legacy `MechaSoonelians.xcodeproj` remains available; both targets compile the same capture and scanning sources and use `Rally/Design.swift` for their capture screens.

A SwiftUI iOS app for creating a lobby, sharing a six-digit room code, and getting everyone ready. The native screens follow the approved HTML preview: cream surfaces, lime action buttons, illustrated avatars, and a glass Join / Create navigation bar.

## Run the app

Requires Xcode 26 or later (for the glass API); supports iOS 18 and later. iOS 26 uses Liquid Glass; earlier versions use a material capsule. The generated `Rally.xcodeproj` is committed, so XcodeGen is not needed to open or run it.

1. Start the Next.js API server with Node.js 22 or later:

   ```sh
   cd server
   npm ci
   npm run dev
   ```

2. Open `Rally.xcodeproj`, choose the **Rally** scheme, and select an iPhone Simulator or connected iPhone. For a physical iPhone, select your development team under Signing & Capabilities.
3. Run the app. Simulator defaults to `http://localhost:3000`. On a physical iPhone, open **Settings → Apps → Rally → Server address** and enter `http://<your-Mac-Wi-Fi-IP>:3000`. Everyone needs the same server. A failed connection also exposes **Connection settings** in Rally.
4. Choose **Create**, enter a nickname, choose an avatar, and create the room. On another device, choose **Join**, enter that room's code, and complete your profile. **Studio** also works without joining a lobby.

The host can copy/share the code, lock the room, remove players, and start once at least two players are present and everyone is ready. Guests can toggle readiness and leave. Ending a room returns everyone to Join. A started session is a shared status screen; quiz questions and gameplay are outside this lobby app's scope.

Invite links use `rally://join/123456`. They fill the Join screen with the code; both devices still need the same server configured.

## Capture Studio

- Open **Studio → Make a player** without connecting to a server, or open **Studio** from an active lobby. Lobby membership and polling remain active while editing.
- The bundled, attributed TUM/Kinect RGB-depth sample includes two people. Switch between Photo, Cutout, Depth and Pose; select a person, adjust joints or try a preset, then save. Simulator uses cached sample analysis when its Vision models are unavailable.
- **Scan person** detects people before capture. Supported LiDAR devices attach depth; ordinary photos still support cutouts and 2D joints. Import preserves embedded depth when available. Live capture and RoomPlan need physical-device verification.
- **Scan your house** captures multiple rooms in one AR coordinate space and saves the structure, USDZ and world map. A new completed house scan replaces the previous one. This action is unavailable on unsupported hardware.
- Saved characters appear under **Your players** with a preview and PNG sharing. Full exports are in **Files → Rally → Players**; house exports are in **Files → Rally → House**. Exports from the legacy Mecha Soonelians app remain in that app’s separate sandbox; they are not automatically migrated.
- The original **Pose** tab remains a 2D articulated cutout; large rotations can expose gaps. **Make a 3D character** uses the Tripo flow below. Original depth is not reposed. The 3D editor supports painting, placement and lobby disguises; natural-language pose prompts are not implemented.

## Tripo 3D characters

1. Keep `TRIPO_API_KEY=...` in the root `.env` (the existing `TRIPO_AI_API_KEY` spelling also works). Never put the key in Swift, a plist, a client token field, or Git.
2. Run `cd server && npm run start:3d`. This starts a separate, localhost-only service on port **3001** and loads the root `.env`. Leave it running while generating. The lobby still uses port 3000.
3. In **Studio → Make a player**, select a person, then **Make a 3D character**. The input is a padded PNG of that person’s original transparent cutout, not the full room or the distorted 2D pose.
4. Confirm the upload/credit notice. The service uploads to Tripo v3, generates a textured 20k-face mesh, checks riggability, and requests a Mixamo-named humanoid GLB rig when compatible. If rigging fails, it keeps the unrigged mesh and explains the limitation.
5. Open the eight-sector **Pose wheel**, drag toward a pose and release; tap its center for the second page (16 poses). Joint sliders use constrained bend/twist/swing offsets with smooth transitions. Drag to orbit and pinch to zoom.
6. **Paint** directly on the skinned surface. Use the color wheel, eyedropper, brush size, opacity, erase, undo/redo, fills, metallic/roughness and shadow controls. **Place** attaches the body to scanned-room surfaces or the practice room, nudges it, changes size/form, and freezes up to two painted clones.
7. **Save character** exports a textured, skinned GLB, thumbnail, pose, `paint.json` and `scene.json`. Reopen it in **Studio → 3D characters**. The original source mesh stays unchanged; a clone keeps its own pose, transform and paint.

The original mesh, exported mesh, source cutout, attribution, pose and generation receipt are stored under **Files → Rally → Characters3D**. The source mesh remains untouched so saved poses can be reset. Generation resumes from Studio if you leave the editor or relaunch; leaving does **not** cancel the remote task or refund credits. Repeating a request uses its saved request ID, avoiding another paid submission. If submission is interrupted before a task ID is recorded, inspect Tripo rather than blindly regenerating.

The Mac service keeps job metadata and models in ignored `artifacts/tripo/`. It uses at most two active jobs and ten new jobs per rolling day by default. It persists Tripo task IDs to recover polling after restart. It does not automatically retry paid task creation. Requests from browsers are rejected; model URLs come only from Tripo, are restricted to its HTTPS domains, and never receive the API key. The bundled viewer makes no CDN requests and rejects external GLB dependencies.

For a physical iPhone on trusted Wi-Fi, set a separate long random `TRIPO_PROXY_TOKEN` in `.env`, start with `TRIPO_HOST=0.0.0.0`, then enter `http://<Mac Wi-Fi IP>:3001` and that proxy token in the 3D editor. The token is kept in memory only. Use HTTPS for anything beyond isolated local development. This single-user proxy is **not** a production multi-user service; add per-user authentication, quotas and private object storage before deployment.

A generated back side is an AI approximation, not measured body geometry. The seated Kinect sample can produce fused surfaces that stretch badly; cropped feet can remain missing. The capture flow warns before using credits when it cannot verify hands/feet or detects foreshortened legs. Use a full-body standing A/T-pose with separated limbs. Pose changes preserve bone lengths; sliders constrain rotations and the editor warns about high mesh stretch, but this is not full-body IK, a self-collision solver, or a guarantee of lifelike skinning. Generated scale is not calibrated to RoomPlan or LiDAR. Rounded/blocky forms are explicit alternative disguises, not reconstructed anatomy.

## Hide-and-seek mechanics

The [reference-video inventory](Docs/GameplayMechanics.md) maps the observed mechanics and timestamps to the app. These are touch adaptations in Rally's cream/lime style, not a copy of the game's art or an exact reproduction of undocumented physics/scoring.

- Join/create a Rally lobby and open **Studio → 3D characters → Play**. Each hider must **Publish disguise**; this explicitly shares their saved mesh, textures and clone placements with room members. Publishing is separate from saving locally. Keep the Studio editor open during play.
- The host chooses **Basic**, **Infection**, **Double**, or **Chicken race**, preparation/hunt duration and optional 30-second whistles, then starts the round. The host is the initial hunter in Basic/Infection. The host's room geometry is shared with all clients, including door/window openings; RoomPlan objects are approximate boxes, not photo-textured surfaces.
- Hunters wait during preparation, then tap actual rendered disguises to tag, drag to look and use arrows to walk. Camera spawning uses room floors and movement checks room triangles. Finding any clone finds its owner; Infection converts that owner into a hunter. Double tracks each hunter's unique finds; Chicken reveals one target at a time. Tags award 500 points. Visible, untagged hiders earn 10 points/second using server-side frustum/room-occlusion estimates; this rate is app-specific.
- Paint can sample a room surface; optional own-body-through-wall rendering helps paint occluded areas. Manual whistles and configurable automatic hints work during hunts. Without a lobby, **Play → Start 60-second practice hunt** tests tags against actual local mesh triangles.
- Disguises are authenticated, self-contained GLBs (20 MB maximum), private to the lobby, with a 256 MB combined in-memory cap. Preparation/mode visibility, host controls, tag cooldowns, clone bounds and room occlusion are checked on the server. Client triangle hits plus server bounding-box checks are prototype hit validation, not production anti-cheat. Restarting the Next.js process clears matches and published disguises.

This does not implement Steam Workshop maps, Steam friends, external voice chat, or the original game's assets. It renders a virtual scanned room; physical-device AR alignment/occlusion and a multi-iPhone play session still need hardware verification.

API contracts: [image-to-model](https://developers.tripo3d.ai/en/docs/generation-image-to-model/standard), [rig check](https://developers.tripo3d.ai/en/docs/animations-rig-check), [auto-rig](https://developers.tripo3d.ai/en/docs/animations-rig), [task query](https://developers.tripo3d.ai/en/docs/task-query).

The local GLB viewer is bundled from pinned Three.js dependencies. To rebuild it:

```sh
npm ci --prefix Tools/CharacterViewer
npm run build --prefix Tools/CharacterViewer
```

Its license is included in the app’s `CharacterViewer` resources. No Node dependencies or API keys are included in the iOS app. Deterministic tests use a clearly synthetic two-bone fixture. Additional end-to-end tests use an existing real Tripo-generated human when present and never initiate paid generation themselves.

## Room lifecycle

Rooms have no configured player cap. The lobby displays the current player count and grows as people join.

- The server generates unique room codes and separate cryptographic membership tokens. Room reads require membership; lock, remove, start, and reset actions require the host.
- The app polls while active, shows reconnection state after a network failure, and saves its membership token in the device Keychain for restoration.
- An inactive guest expires after 90 seconds without a heartbeat. If the host expires or ends the room, the entire room closes. Keeping the host app in the background for over 90 seconds can therefore end the room.
- Rooms are stored in memory in one persistent Next.js process. Restarting that process clears them. Development route recompilation reuses the same store. Deploy a single Node.js instance; serverless functions or multiple replicas require a shared database before they can reliably host rooms.
- `PORT` defaults to `3000`; the scripts bind to `0.0.0.0` to allow devices on your Wi-Fi. For localhost-only use, run `npx next dev --hostname 127.0.0.1`. Deploy behind HTTPS to use across networks.

## Next.js server

The API lives in `server/pages/api/[...path].js`, backed by `server/lib/lobby.mjs` and `server/lib/game.mjs`. Next.js rewrites keep the Swift client's `/health`, `/rooms`, and `/rooms/:code/...` URLs working. Lobby JSON requests retain the 4 KB limit; game configuration accepts 256 KB and binary disguise uploads accept 20 MB. `/rooms/:code/game` handles snapshots/start/shoot/taunt/view; `/rooms/:code/disguise` publishes and `/rooms/:code/disguise/:ownerID` reads a phase-authorized mesh. Public/lobby mutation limits use the socket address rather than trusting forwarded headers; authenticated game actions use per-player budgets so hunters sharing Wi-Fi do not exhaust each other's camera-update allowance.

For a production server:

```sh
cd server
npm ci
npm run build
npm start
```

Health check: `GET http://localhost:3000/health`. The HTML design preview remains a separate simulated UI.

## HTML design preview

```sh
python3 -m http.server 4173 --bind 127.0.0.1 --directory preview
```

Open <http://127.0.0.1:4173> in Codex's browser. This preview uses simulated in-memory data; it does not connect to the server. Join its sample room with `482916`, or create a room and use the simulation controls below it. Refreshing resets the preview. The native app uses actual server-generated codes, not a fixed sample code.

## Validation

Server integration tests cover multi-client lifecycle, host permissions, token isolation, concurrent joins beyond 20 players, locking, validation, expiry, and limits:

```sh
cd server
npm test
npm run build
npm run test:integration
```

Viewer geometry checks: `npm test --prefix Tools/CharacterViewer`. They cover Mixamo name normalization, input-facing-direction independence, exact floor/wall contact, actual doorway triangles and floor-based hunter spawns.

Run native unit and UI tests in Xcode with **Product → Test** once an iOS Simulator runtime is installed. The unit suite covers room readiness and server-address validation; the UI suite covers Join / Create navigation and form validation.

The native API client can also be checked against a running server without Simulator:

```sh
mkdir -p artifacts
swiftc Rally/Models.swift scripts/native-api-smoke.swift -o artifacts/native-api-smoke
artifacts/native-api-smoke http://localhost:3000
```

To regenerate the project after changing `rally.yml`, run `xcodegen generate --spec rally.yml`. To compile the app without device signing:

```sh
xcodebuild -project Rally.xcodeproj -target Rally -sdk iphonesimulator \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Build output and screenshots are ignored by Git. App Store signing and server hosting are not configured in this repository.

### Verification in this checkout

The validation suite includes native unit/UI tests, 20 server tests, four viewer geometry tests and production Next.js integration. The real-human WebKit test applies every preset, verifies world-space bone lengths, actually paints/undoes/redoes, turns front/back, freezes two clones, exports/reopens, checks texture/clone persistence and tags actual skinned triangles. The UI test selects a wheel pose, draws on the human, undoes/redoes, saves and reopens; it also guards against iOS 26's full-screen back-swipe stealing canvas gestures. `CharacterGameTests` uses two native editors to publish a real generated GLB, load it in the hunter's renderer and tag its actual triangles through Next.js. Start an isolated production server with `cd server && npx next start --hostname 127.0.0.1 --port 3099` to run that test. Tests requiring an existing generated human explicitly skip when none is installed; the native multiplayer test also skips if its isolated server is absent. Screenshots and mesh-stretch reports are written under the Simulator app's `Documents/Verification/character-gameplay` and copied to ignored `artifacts/gameplay-verification/` during verification. Live camera depth, RoomPlan/AR registration and multi-iPhone gameplay still need physical-device testing.
