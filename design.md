# MecchaSoonelians — native Jelly design

The user-selected source is `server/public/play/index.html`, `variants/lobby.css`,
`variants/lobby.js`, and `variants/sfx.js`. This replaces the original Rally join,
create, and lobby presentation. Studio and its capture/editor tools retain their
existing layout and functionality.

## Visual system

Playful full-screen physics scene, followed by a centered form or lobby card over
the blurred scene. Background #e4e7ef, paper #fbfbfb, ink #141414, blue #4a63ff,
muted #6b7080, fields #f1f2f6, success #1f8f5f, error #c0392b. Shared native tokens
live in `MechaSoonelians/Shared/JellyTokens.swift`; components are in
`MechaSoonelians/Lobby/JellyStyle.swift`. Outfit ExtraBold display, Nunito Bold body; both
fonts are bundled with their OFL licenses so the design works offline.

Cards have a 2-point ink outline, 26-point corners, 24-point padding, and a soft
shadow. Inputs and action buttons have 16-point corners. Primary actions use
blue/white; secondary actions use an ink outline. Interactive targets are at
least 44 points. Focus is blue. Typography scales with Dynamic Type, and forms
scroll when the keyboard or accessibility text sizes need more room.

## Scene and motion

`JellyScene.swift` uses the eight supplied figurine masks, outlined in black/white,
blue SOON letters and the geometric logo. SpriteKit supplies gravity, collisions,
drag/throw, and the physical PLAY/title cards. Core Motion tilt is opt-in on
supported devices; Simulator exposes drag instead. The pile blurs after settling;
the two cards stay sharp. The HUD has tilt on the left and sound on the right; the counter and refill action
are removed. Strong shakes toss pieces within the screen bounds. Reduce Motion renders an
immediate static pile and accessible PLAY button with no falling or tilt.

The supplied BGM loops after the pour. Native PCM clicks follow the source's
noise/sine envelopes for typing, buttons, and submission. Mute persists. Audio
respects Silent Mode, pauses in the background and Studio, and mixes with other
apps. Native physics and synthesized audio approximate the browser engines;
they do not embed or require the web page.

## Flows

PLAY → six-digit code → name/avatar/3D figure → joined room. “Host a game” branches from
the code card to name/avatar/3D figure → new room. The existing Rally API and Keychain
membership remain authoritative. Guests join as not ready and press Ready explicitly.
Once ready, their status confirms it and the button becomes Un-ready. Host start
still requires all players ready. Host and join identity forms no longer show
avatar color choices.

The lobby uses a bounded scrolling list without a player cap. Copy, share,
lock/unlock, remove player, start/reset, and confirmed end/leave remain available.
Studio entry points are removed from the landing HUD and room options. Starting
a game opens the online AR round. Reconnection, server errors, connection settings, and deep links
remain native. The web reference's demo fallback is deliberately not used.

## Verification

`JellyTests` checks bundled assets/fonts and reduced-motion layouts at compact
iPhone, standard iPhone, and landscape iPad sizes. `RallyUITests` covers navigation,
numeric input, color selection, real API hosting/joining, a seven-player scrolling
list, start/reset/end, guest leave, and Studio access. The lobby integration tests
require the local Next.js server on port 3000.

Verified on iPhone 17 Pro Simulator: native build, asset/reduced-motion tests,
host/guest API flows, seven-player scrolling, and navigation at the largest
accessibility text size. Existing unit tests passed; five pre-existing tests
requiring optional generated-character or game-server fixtures were skipped.
Physical-device tilt and listening checks for audio remain hardware checks.

## Online round screens (2026-10-24)

`MechaSoonelians/Game/GameView.swift` uses the Jelly system for player readiness,
seeker reveal, hiding/seeking overlays, waiting timers, chirp controls, map loading,
and results. The wordmark is two lines: MECCHA above SOONELIANS, with SOON in blue.
Full-page backgrounds are cool grey; panels are paper with 2-point ink outlines.
Primary actions and timers are blue/white. Secondary actions are outlined; leave
and end actions remain destructive and keep their existing confirmation dialogs.
Player portraits use the same name-matched assets as the lobby. Ready state,
roles, scoring and game actions remain driven by the existing round state.

Readiness uses a responsive player grid, switching to one column at accessibility
text sizes. Waiting screens scroll when content exceeds the screen height.
Results retain winner, score, found status, replay and hiding-spot actions.

## Remaining legacy styling

- Advanced 3D editing: the editor at the top of `Capture/Character3DView.swift`,
  `CharacterStudioView.swift`, `CharacterWebView.swift` and `CharacterEditing.swift`.
- Capture and pose tools: `Capture/PersonCameraView.swift`, `CaptureEditorView.swift`
  and `PoseCanvas.swift`.
- Pose wheel in `Capture/CharacterEditing.swift` and older capture tools:
  `PaintView.swift`, `Ghost3DView.swift` and `ChameleonStudioView.swift`.
- Studio hub: `Lobby/StudioView.swift`.
- Embedded character viewer/game HTML also needs its own visual audit before migration.

Those screens still reference `RallyStyle`, the warm paper/lime palette, rounded
system fonts, or legacy brand/buttons. They are outside this round-screen update.

Visual QA renders the actual round panels offline through the DEBUG-only preview
entrypoint and `JellyTests.testRoundPanelsRenderForVisualReview`, at standard and
accessibility text sizes. It does not start the camera or connect to a game server.

## Personal figure gallery

Character setup no longer interrupts Play. The identity card places “Your 3D figure”
below the avatar choices. Create/Join and keyboard submission require a valid model,
rig, baked pose archive, and texture. Opening the row shows saved figures; tapping a
figure opens an interactive 3D preview and selection or preparation action. Unrigged
meshes remain visible but cannot be selected for play.

The + action opens a blue Jelly capture/photo sheet and always creates a separate
saved figure. A root-owned preparation worker continues after sheets close.
A top progress header covers generation, download and pose preparation, then
disappears on completion. Failure clears the busy header and displays a gallery
message; saved unfinished jobs can be retried. Relaunch resumes the persisted
request ID. iOS may suspend work while the app is backgrounded.

Capture consent remains beside upload/scan actions. Tests use bundled models and
mock network responses; they do not request paid generation.

## Host play-room picker

The host's lobby has a “Play room” row before timing controls and Start game.
It opens an interactive interior preview with orbit/zoom, saved-room choices,
and an Add new room action. Selection is explicit; browsing another preview
does not change the active room. Selection is disabled while the preview is
unavailable. New scans have a name and save independently under
`Documents/SavedRooms/<UUID>`; the old `Documents/House` scan remains accessible.

The selected structure and world map are used by the host's AR session and the
existing multiplayer map upload. The included room uses its existing bundled
map identifier. A missing selected room blocks starting instead of silently
switching physical spaces. Scan saving stages a complete export, validates it,
then publishes it atomically; failures preserve earlier rooms.

The picker and scan controls use Jelly colors/fonts. Scanning requires RoomPlan
support (LiDAR); viewing and choosing saved rooms does not. RoomPlan's native
capture visualization remains native. Tests cover multiple saved scans, failed
saves, selection/host-map consistency, missing selections, preview readiness,
and rendering at 320/375/414/768-point widths.

## Spray controls

The AR spray overlay uses a compact Jelly status bar and a fixed bottom control
panel. Move joystick, pose switch, and a combined Pick/Spray button remain visible
in stable positions. Aiming at the room shows Pick color; aiming at the figure
shows Hold to spray. Each press keeps its starting action until released, so a
color-picking press cannot unexpectedly turn into spraying. The transparent crosshair's
colored ring is the sole paint-color indicator; there is no separate filled swatch.
Rotation and Spray size have labeled sliders and numeric values. The To floor and
Against wall buttons are removed; direct dragging, pinching and turning remain.
On shorter screens the sliders sit below the top status bar to keep the central
aiming point clear while all controls remain visible.
Pick color uses pale blue with dark text; Hold to spray uses solid blue with white
text, darkening while spraying. The label and icon also distinguish both modes.
Tap Pose to open all saved poses in a scrollable three-column picker. Blocked
poses remain visible with a Needs space label rather than being silently skipped.
Leaving the editor or
backgrounding the app stops movement and spraying. The compact gameplay controls
cap Dynamic Type at xxxLarge and retain VoiceOver labels and actions.

After placement, Hide somewhere else is an outlined secondary action. The host's
primary action reads Ready to be found and opens the existing Start seeking
confirmation, which explains that advancing ends hiding for everyone.

## Seeker paint shots

Seeking uses a centered green-ring crosshair and a Shoot action. Each press sends
a short green projectile toward the aiming point, with a 250 ms rate limit.
Painted figures use their posed triangle meshes for targeting. Scanned walls and
furniture, detected planes, nearer figures and the 12 m range stop shots; scanned
doorways remain passable. Legacy cutouts/USDZ models retain collision targeting.

The server confirms finds. A confirmed hit restores the figure's original texture,
keeps it visible with a green marker, and shows Found Ya! above the crosshair for
two seconds. The last hit briefly holds the AR reveal before results. Failed tag
requests can be retried. New body transfers include the original texture; legacy
body transfers without one reveal the neutral unpainted body instead. This does
not change the saved profile or the original uploaded camouflage image.

## Round leaderboard

Results show every player ranked by their accumulated room score. Each row has
the total in ink and this round's +points in blue, including +0. Equal totals
share a rank. The server carries completed points into the next Play again round
under the existing room lock; polling cannot add them twice. Existing round
winner and scoring rules stay unchanged. Returning to the lobby resets the
scoreboard. The hiding-spots action and view are removed from results.
