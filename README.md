# Rally

This repository also contains the separate MechaSoonelians RoomPlan scanner project. Open `Rally.xcodeproj` for the lobby app; `project.yml` belongs to the scanner and `rally.yml` generates Rally.

A SwiftUI iOS app for creating a lobby, sharing a six-digit room code, and getting everyone ready. The native screens follow the approved HTML preview: cream surfaces, lime action buttons, illustrated avatars, and a glass Join / Create navigation bar.

## Run the app

Requires Xcode 26 or later (for the glass API); supports iOS 17 and later. iOS 26 uses Liquid Glass; earlier versions use a material capsule. The generated `Rally.xcodeproj` is committed, so XcodeGen is not needed to open or run it.

1. Start the Next.js API server with Node.js 22 or later:

   ```sh
   cd server
   npm ci
   npm run dev
   ```

2. Open `Rally.xcodeproj`, choose the **Rally** scheme, and select an iPhone Simulator or connected iPhone. Install an iOS runtime through Xcode's Components settings if necessary. For a physical iPhone, select your development team under Signing & Capabilities.
3. Run the app. Simulator defaults to `http://localhost:3000`. On a physical iPhone, open **Settings → Apps → Rally → Server address** and enter `http://<your-Mac-Wi-Fi-IP>:3000`. Return to Rally and allow local-network access. Everyone must use the same server; a public server requires HTTPS. A failed connection also exposes **Connection settings** in Rally so you can correct and test the address.
4. Choose **Create**, enter a nickname, choose an avatar, and create the room. On another device, choose **Join**, enter that room's code, and complete your profile.

The host can copy/share the code, lock the room, remove players, and start once at least two players are present and everyone is ready. Guests can toggle readiness and leave. Ending a room returns everyone to Join. A started session is a shared status screen; quiz questions and gameplay are outside this lobby app's scope.

Invite links use `rally://join/123456`. They fill the Join screen with the code; both devices still need the same server configured.

## Room lifecycle

Rooms have no configured player cap. The lobby displays the current player count and grows as people join.

- The server generates unique room codes and separate cryptographic membership tokens. Room reads require membership; lock, remove, start, and reset actions require the host.
- The app polls while active, shows reconnection state after a network failure, and saves its membership token in the device Keychain for restoration.
- An inactive guest expires after 90 seconds without a heartbeat. If the host expires or ends the room, the entire room closes. Keeping the host app in the background for over 90 seconds can therefore end the room.
- Rooms are stored in memory in one persistent Next.js process. Restarting that process clears them. Development route recompilation reuses the same store. Deploy a single Node.js instance; serverless functions or multiple replicas require a shared database before they can reliably host rooms.
- `PORT` defaults to `3000`; the scripts bind to `0.0.0.0` to allow devices on your Wi-Fi. For localhost-only use, run `npx next dev --hostname 127.0.0.1`. Deploy behind HTTPS to use across networks.

## Next.js server

The API lives in `server/pages/api/[...path].js`, backed by `server/lib/lobby.mjs`. Next.js rewrites keep the Swift client's existing `/health`, `/rooms`, and `/rooms/:code/...` URLs working. JSON responses, membership tokens, host permissions, validation, and uncapped room membership are unchanged. Request bodies retain the 4 KB limit; mutation limits use the socket address rather than trusting forwarded headers. Behind a proxy, clients may share that rate-limit bucket.

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

The six server tests, the production Next.js integration suite, three shared-model tests (executed on macOS), and the native API smoke test passed. The Next.js production build passed, and the Swift API smoke test was run against it. The app, unit-test target, and UI-test target compiled for the Simulator SDK with asset-catalog processing excluded. Full icon processing and Simulator UI execution still require the missing iOS runtime; a runtime must finish installing first. After installing it, run the standard build and Xcode tests above.
