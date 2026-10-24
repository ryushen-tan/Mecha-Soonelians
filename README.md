# Rally

Open `Rally.xcodeproj` for the integrated app: lobbies, RoomPlan scanning, and the human capture/pose Studio. `rally.yml` generates Rally. The legacy `MechaSoonelians.xcodeproj` remains available; both targets compile the same capture and scanning sources and use `Rally/Design.swift` for their capture screens.

A SwiftUI iOS app for creating a lobby, sharing a six-digit room code, and getting everyone ready. The native landing and lobby now follow the Jelly design in `server/public/play`: a SpriteKit pile of black/white figurines and blue letters, physical PLAY/title cards, and outlined forms over a blurred scene. The supplied sprites, soundtrack, Outfit, and Nunito fonts are bundled for offline rendering. See [design.md](design.md) for the native adaptation.

## Run the app

Requires Xcode 26 or later (Studio uses the glass API); supports iOS 18 and later. The generated `Rally.xcodeproj` is committed, so XcodeGen is not needed to open or run it. Simulator builds do not require a development team.

1. Start the Next.js API server with Node.js 22 or later:

   ```sh
   cd server
   npm ci
   npm run dev
   ```

2. Open `Rally.xcodeproj`, choose the **Rally** scheme, and select an iPhone Simulator or connected iPhone. For a physical iPhone, select your development team under Signing & Capabilities.
3. 3D characters use the hosted service at `https://mecha-soonelians.vercel.app` by default (see **Hosted 3D service** below); nothing needs to run on your Mac. On first launch, complete **Scan & create my 3D self** (or choose a full-body photo). Setup automatically cuts out the person, generates and rigs the Tripo model, and saves it. See **First-launch character setup** below for iPhone connection settings.
4. Once setup finishes, the lobby defaults to the hosted server at `https://mecha-soonelians.vercel.app`. To use a local server instead, open **Settings → Apps → Rally → Server address** and enter `http://localhost:3000` (Simulator) or `http://<your-Mac-Wi-Fi-IP>:3000` (iPhone), or launch with `-server-url <address>`. Everyone needs the same lobby server. A failed connection also exposes **Connection settings** in Rally.
5. Tap **PLAY → host a game**, enter a nickname, pick a color, and create the room. On another device, tap **PLAY**, enter that room's code, and complete your profile. Guests are ready on entry and can toggle readiness. **Studio** opens from the landing viewfinder button or the lobby's **…** menu, and works without joining a lobby.

Drag and throw the landing figurines, or enable tilt on a physical phone. **Pour again** restarts the scene. The soundtrack starts after the pour; **Sound on/off** controls music and keyboard clicks together. Audio respects Silent Mode and pauses in the background or Studio. Reduce Motion presents a static pile with PLAY immediately available.

The host can copy/share the code, lock the room, remove players, and start once at least two players are present and everyone is ready. Guests can toggle readiness and leave. Ending a room returns everyone to Join. A started session is a shared status screen; quiz questions and gameplay are outside this lobby app's scope.

Invite links use `rally://join/123456`. They fill the Join screen with the code; both devices still need the same server configured.

## Capture Studio

- Open **Studio → Make a player** without connecting to a server, or open **Studio** from an active lobby. Lobby membership and polling remain active while editing.
- The bundled, attributed TUM/Kinect RGB-depth sample includes two people. Switch between Photo, Cutout, Depth and Pose; select a person, adjust joints or try a preset, then save. Simulator uses cached sample analysis when its Vision models are unavailable.
- **Scan person** uses a five-second selfie countdown so you can prop the phone up and step back before the photo. You can cancel the timer; closing or backgrounding the camera also cancels it. Human detection runs while framing, but starting the timer does not require you to already be in frame. Supported depth cameras attach depth; ordinary photos still support cutouts and 2D joints. Import preserves embedded depth when available. Live capture and RoomPlan need physical-device verification.
- **Scan your house** captures multiple rooms in one AR coordinate space and saves the structure, USDZ and world map. A new completed house scan replaces the previous one. This action is unavailable on unsupported hardware.
- Saved characters appear under **Your players** with a preview and PNG sharing. Full exports are in **Files → Rally → Players**; house exports are in **Files → Rally → House**. Exports from the legacy Mecha Soonelians app remain in that app’s separate sandbox; they are not automatically migrated.
- The original **Pose** tab remains a 2D articulated cutout; large rotations can expose gaps. **Make a 3D character** uses the Tripo flow below. Original depth is not reposed. The 3D editor supports painting, placement and lobby disguises; natural-language pose prompts are not implemented.

## Tripo 3D characters

### First-launch character setup

Both app targets now require a personal rigged character before opening the home/lobby screen. The `white-3d` AR placement/spray flow is retained in **MechaSoonelians**, but hiders use their own scanned Tripo body instead of the bundled white mannequin.

- Setup explains the upload and credit use before opening the camera/photo picker. A single complete person is cropped and sent automatically, explicitly requesting humanoid rigging. Multiple people require choosing one. Missing hands/feet or a seated capture blocks automatic submission and asks for a clearer standing photo.
- Open **3D server** to configure the service. Both apps default to the hosted service and its built-in access token. For a local service, Simulator can use `http://localhost:3001`; a physical iPhone needs `http://<Mac-Wi-Fi-IP>:3001`, with `TRIPO_HOST=0.0.0.0` and `TRIPO_PROXY_TOKEN` configured on the Mac. The proxy token is stored in the device Keychain, not the Tripo API key. Launch arguments `--model-server <address> --model-token <proxy-token>` also work.
- The personal character ID and input are saved **before** submitting. Relaunching resumes the same UUID/job, not a fresh paid generation. A failed rig is kept for inspection but does not count as a playable character; retaking is explicit and warns that it starts a new paid job. No automatic paid retries are made.
- Existing personal rigged source models are reused offline. Setup prepares a shared texture atlas and 15 baked poses from the actual skinned mesh without changing the saved GLB. Future launches skip setup when the saved rigged model, pose geometry and texture are present. Attributed demo/sample assets are not automatically chosen as your identity.
- The AR editor starts with that model's texture, keeps paint aligned across pose changes, and transfers the hider's actual posed geometry and paint to peers. A seeker does not substitute their own body or the white mannequin. The original rigged GLB remains available in Studio for joint editing.
- Saved identity is local to each app/device sandbox, not an account or cloud backup. Camera capture, LiDAR, AR alignment and multi-iPhone transfer still need physical-device testing.

### Additional Studio characters

1. Keep `TRIPO_API_KEY=...` in the root `.env` (the existing `TRIPO_AI_API_KEY` spelling also works). Never put the key in Swift, a plist, a client token field, or Git.
2. The hosted service handles generation. To run it locally instead, run `cd server && npm run start:3d`. This starts a separate, localhost-only service on port **3001** and loads the root `.env`. Leave it running while generating. The lobby still uses port 3000.
3. In **Studio → Make a player**, select a person, then **Make a 3D character**. The input is a padded PNG of that person’s original transparent cutout, not the full room or the distorted 2D pose.
4. Confirm the upload/credit notice. The service uploads to Tripo v3, generates a textured 20k-face mesh, checks riggability, and requests a Mixamo-named humanoid GLB rig when compatible. If rigging fails, it keeps the unrigged mesh and explains the limitation.
5. The editor opens as an edge-to-edge 3D room with a minimal floating HUD, not a form beneath a preview. In **Position & pose**, tap the person to select them and drag the mesh directly. **Move** shows translation arrows, **Rotate** shows X/Y/Z rotation rings, and **Size** shows resize handles; resizing stays uniform to preserve body proportions. You can also drag the body to turn it in Rotate or drag up/down to resize in Size. Drag the background to orbit; pinch with two fingers to zoom without moving the person. **Pose** opens the two-page, 16-pose wheel. **… → More tools** contains surface attachment, **To floor**, wall placement, body size (down to 15%), joints, forms and clones. The entire posed body must fit; moving, rotating or resizing cannot push it into scanned walls or furniture.
6. Tap the floating **lock** to paint without moving the body. A compact brush/color/undo bar replaces the transform tools and hides the selection gizmo; detailed paint controls open from its color swatch. Pinch to zoom, pan with two fingers, and paint with one. Zooming closer produces finer world-space marks, and two-finger navigation cancels accidental initial paint. The top mode menu switches back to placement without discarding paint. **… → Frame character** resets the view. Room backgrounds use colored RoomPlan geometry, not photographic textures or a live camera feed.
7. The floating **checkmark** saves a textured, skinned GLB, thumbnail, pose, `paint.json` and `scene.json`, including the locked editor state. Reopen it in **Studio → 3D characters**. Closing with unsaved changes offers save-and-close or discard. The original source mesh stays unchanged; a clone keeps its own pose, transform and paint.

The original mesh, exported mesh, source cutout, attribution, pose and generation receipt are stored under **Files → Rally → Characters3D**. The source mesh remains untouched so saved poses can be reset. Generation resumes from Studio if you leave the editor or relaunch; leaving does **not** cancel the remote task or refund credits. Repeating a request uses its saved request ID, avoiding another paid submission. If submission is interrupted before a task ID is recorded, inspect Tripo rather than blindly regenerating.

The Mac service keeps job metadata and models in ignored `artifacts/tripo/`. It uses at most two active jobs and ten new jobs per rolling day by default. It persists Tripo task IDs to recover polling after restart. It does not automatically retry paid task creation. Requests from browsers are rejected; model URLs come only from Tripo, are restricted to its HTTPS domains, and never receive the API key. The bundled viewer makes no CDN requests and rejects external GLB dependencies.

### Hosted 3D service

The Vercel deployment serves the same `/characters` API from `server/lib/characters.mjs`. Nothing runs between requests: each status poll from the app checks Tripo once and, when a stage finishes, submits the next one. Before a paid submission, the server claims the job with a conditional (ETag) write, so concurrent polls never submit the same stage twice. Job state and generated GLBs live in the private Vercel Blob store `mecha-soonelians-3d`. `/characters/:id/model` redirects to a 15-minute presigned download, because models exceed Vercel's 4.5 MB response limit. Uploads are also limited to 4.5 MB by Vercel; the app's 1024 px cutouts fit.

Vercel production holds `TRIPO_API_KEY`, `TRIPO_PROXY_TOKEN` and `BLOB_READ_WRITE_TOKEN`. The apps build in the proxy token (`HostedCharacterService` in `MechaSoonelians/Capture/Character3DModel.swift`), so anyone with the app binary can extract it. The server-wide limit of 100 new generations per rolling day (`TRIPO_DAILY_LIMIT`) is what protects your credits. To rotate the token, update it with `vercel env add TRIPO_PROXY_TOKEN production --force`, redeploy, and ship the new value in the apps.

For a physical iPhone on trusted Wi-Fi, set a separate long random `TRIPO_PROXY_TOKEN` in `.env`, start with `TRIPO_HOST=0.0.0.0`, then enter `http://<Mac Wi-Fi IP>:3001` and that proxy token in setup. Setup saves the proxy token in the Keychain; additional Studio characters reuse it. Use HTTPS for anything beyond isolated local development. This single-user proxy is **not** a production multi-user service; add per-user authentication, quotas and private object storage before deployment.

A generated back side is an AI approximation, not measured body geometry. The seated Kinect sample can produce fused surfaces that stretch badly; cropped feet can remain missing. The capture flow warns before using credits when it cannot verify hands/feet or detects foreshortened legs. Use a full-body standing A/T-pose with separated limbs. Pose changes preserve bone lengths; sliders constrain rotations and the editor warns about high mesh stretch, but this is not full-body IK, a self-collision solver, or a guarantee of lifelike skinning. Generated scale is not calibrated to RoomPlan or LiDAR. Rounded/blocky forms are explicit alternative disguises, not reconstructed anatomy.

## Hide-and-seek mechanics

The [reference-video inventory](Docs/GameplayMechanics.md) maps the observed mechanics and timestamps to the app. These are touch adaptations in Rally's cream/lime style, not a copy of the game's art or an exact reproduction of undocumented physics/scoring.

- Join/create a Rally lobby and open **Studio → 3D characters → … → Game controls**. Lock placement before **Publish disguise**; publishing explicitly shares the saved mesh, textures and clone placements with room members and is separate from saving locally. Keep the Studio editor open during play. Lobby Studio opens full-screen too.
- During a live hunt, **Emergency eject** gives each active hider one server-chosen relocation per round. It moves the body and clones together, preserving paint, size, pose and find history. There is no preview or undo, and no camouflage-quality check: a valid spot can be completely exposed. Spots must fit on a floor without intersecting obstacles; failure does not consume the use. Ordinary editing and republishing are locked during hunts. The server updates hit bounds and seekers receive the same relocation on their next refresh.
- The host chooses **Basic**, **Infection**, **Double**, or **Chicken race**, preparation/hunt duration and optional 30-second whistles, then starts the round. The host is the initial hunter in Basic/Infection. The host's room geometry is shared with all clients, including door/window openings; RoomPlan objects are approximate boxes, not photo-textured surfaces.
- Hunters wait during preparation, then tap actual rendered disguises to tag, drag to look and use arrows to walk. Camera spawning uses room floors and movement checks room triangles. Finding any clone finds its owner; Infection converts that owner into a hunter. Double tracks each hunter's unique finds; Chicken reveals one target at a time. Tags award 500 points. Visible, untagged hiders earn 10 points/second using server-side frustum/room-occlusion estimates; this rate is app-specific.
- Paint can sample a room surface; optional own-body-through-wall rendering helps paint occluded areas. Manual whistles and configurable automatic hints work during hunts. Without a lobby, **Game controls → Start 60-second practice hunt** tests tags against actual local mesh triangles.
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
- Rooms are stored in Supabase (Postgres schema `rally`; disguise GLBs in the private `rally-disguises` bucket), so any number of serverless instances serve the same rooms and memberships survive restarts and redeploys. Each request locks its room row, so concurrent instances apply changes one at a time. Database outages return a retryable `503`, never “room not found”. Setup, behaviour and limits: [Docs/Supabase.md](Docs/Supabase.md). For one local process without Supabase, set `RALLY_STORE=memory`.
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

## Profile avatars

Entering a full name from `Rally/ProfilePhotos/profiles.json` selects that person's AI-blended avatar, ignoring case and repeated whitespace. All 42 available profiles have bundled front, three-quarter, and rear views under `Rally/ProfilePhotos/AIAvatars`. The entry screen and lobby use the front view; **View avatar** opens a Front / Angle / Back selector. Matching and previews work offline. Unmatched names and Jaden Hum (no source photo) keep the selected color avatar.

The PNGs are three-view rendered image sheets, not UV textures or 3D geometry. The app crops each sheet into individual views and caches them with a 32 MB limit. Replacing a sheet requires preserving the front / angle / back order. The generation prompts, original-photo comparisons and complete pack are in `artifacts/profile-avatars/ai-blended`.

The earlier photo-projection mesh and its assets remain available for development in `ProfileAvatarMesh.swift`, `ProfilePhotos/Avatars`, and `Tools/ProfileAvatars`; they are no longer used by the profile preview.

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

Build output and screenshots are ignored by Git. App Store signing is not configured in this repository. The lobby server is deployed to Vercel (`https://mecha-soonelians.vercel.app`) from `server/` with `vercel deploy --prod`; rooms live in Supabase once `RALLY_DATABASE_URL`, `SUPABASE_URL` and `SUPABASE_SECRET_KEY` are set (see [Docs/Supabase.md](Docs/Supabase.md)).

### Verification in this checkout

The validation suite includes 13 native unit/integration tests, three UI tests, 25 server tests, 22 viewer tests and production Next.js integration. Real-human WebKit tests exercise direct mesh dragging (including sideways movement off a wall onto the floor), actual X/Y/Z rotation handles, uniform resizing, gesture cancellation, camera-only pinch zoom, transform persistence, every preset, bone lengths, surface constraints, blocked pose/size changes, painting, undo/redo, locked placement, clones, export/reopen persistence and tags against actual skinned triangles. Simulator UI gestures exercise selection, the Move/Rotate/Size toolbar, the Pose wheel, both editor modes and pinch zoom without accidental paint. `CharacterGameTests` publishes a real generated GLB through two native editors, ejects the hider, verifies matching server/seeker/hider locations and tags the relocated mesh through Next.js.

Start an isolated production server with `cd server && npx next start --hostname 127.0.0.1 --port 3099` for the native multiplayer test. Real-human tests explicitly skip if no generated human is installed; the multiplayer test also skips if its server is absent. Screenshots and stretch reports are written under the app's `Documents/Verification/character-gameplay`. Live camera depth, RoomPlan/AR registration and multi-iPhone gameplay still need physical-device testing.
