# `/play` — the web twin of the app's UI

Static pages served by the Next server from `server/public` (locally `http://localhost:3000/play/…`,
hosted at `https://mecha-soonelians.vercel.app/play/…`). They exist so the UI can be looked at and
tweaked in a browser (or on a phone over Wi‑Fi) without Xcode, and then applied back to the Swift views.

| Page | What it is | Swift reference |
| --- | --- | --- |
| `index.html` | Landing page: black/white figurines, the blue S O O N letters and the logo pour in with bouncy circle physics; the **PLAY** card drops in early, the **MECCHA SOONELIANS** card lands on the pile; the pile blurs once settled and both cards stay sharp. Drag the background to lean gravity, drag a figure to throw it, "Enable tilt" on phones. | `Rally/JellyScene.swift`, `JellyExperienceView.swift` |
| `variants/lobby.js` + `lobby.css` | The cards behind PLAY on the real Rally rooms API: enter code → Join; "host a game" → name + colour → room with code, player list, lock / share / copy, Start game, Ready, End / Leave. One room session per browser tab. | `Rally/HomeView.swift`, `LobbyView.swift`, `JellyStyle.swift` |
| `variants/sfx.js` | Looping BGM (`audio/bgm.mp3`) from the moment the pour is full, synthesized keyboard clicks on buttons and typing, mute toggle. | `Rally/JellyAudio.swift` |
| `studio.html` | The in‑game round as plain HTML, after the AR hide‑and‑seek flow: lobby (host sets hide / seek time, taps roles) → hide (place the chameleon, then the spray‑paint screen) → seek → results. The AR camera and scanned house are replaced by a stub room with a white chameleon body, so everything else (crosshair, Pick / Hold to spray, joystick, pose, timers) can be tried. | `MechaSoonelians/Game/GameView.swift`, `SprayPaintView.swift`, `SprayPainter.swift` |
| `studio-states.html` | Every state of `studio.html` side by side in phone frames. | — |
| `sprites/pose-1..8.png` | The figurine cutouts used by the landing page (outlines are added at runtime). | `Rally/JellyAssets/sprites` |

## What changed, in order

1. **Landing page** rebuilt as the Jelly design: SpriteKit‑like piece sizes and physics, 2D stroked
   letters and logo, physical PLAY and title cards, live blur after settling, English HUD. Sound added.
2. **Lobby cards** rebuilt after `HomeView` / `LobbyView`: code card (Join + arrow, disabled until six
   digits), identity card (YOUR NAME, 1–20 characters, PICK A COLOR), room card (big code for the host,
   "You're in, name!" for guests, ready / start / lock / share / copy / remove). The demo fallback is
   gone; "Connection settings" checks `GET /health` like the app.
3. **In‑game mock** (`studio.html`) after the AR game views, in the Jelly palette:
   - hide / seek durations are set in the lobby before the round and cannot be changed during it;
   - the paint tools are reduced to the spray‑paint screen: aim the **+**, **Pick** takes the colour
     under it from the room, **Hold to spray** when the + is on the body, spray size slider, undo;
     tap the colour circle for a hue wheel + brightness + five swatches;
   - **Pose** steps to the next pose on each tap and wraps around (no wheel).

## Running and tweaking

```sh
cd server && npm run dev        # then open http://localhost:3000/play/index.html
```

`studio.html?state=…` jumps to one state (`lobby-host`, `lobby-guest`, `hide`, `place`, `spray`, `eyes`,
`seek`, `sneaky`, `results`); `&dev=0` hides the state strip at the top. Colours and fonts are the
`:root` tokens at the top of each page (the same values as `JellyStyle.swift`). On an iPhone, open the
Vercel URL (HTTPS is needed for the tilt sensor).

Placeholders, not product: the stub room, the capsule chameleon, the spray blobs and the fake players.
The real app keeps its AR camera, scanned house, Multipeer session and Tripo characters.
