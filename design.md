# Mecha Soonelians — native Jelly design

The user-selected source is `server/public/play/index.html`, `variants/lobby.css`,
`variants/lobby.js`, and `variants/sfx.js`. This replaces the original Rally join,
create, and lobby presentation. Studio and its capture/editor tools retain their
existing layout and functionality.

## Visual system

Playful full-screen physics scene, followed by a centered form or lobby card over
the blurred scene. Background #e4e7ef, paper #fbfbfb, ink #141414, blue #4a63ff,
muted #6b7080, fields #f1f2f6, success #1f8f5f, error #c0392b. Shared native tokens
live in `Rally/JellyStyle.swift`. Outfit ExtraBold display, Nunito Bold body; both
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
the two cards stay sharp. Pour again replaces the pile. Reduce Motion renders an
immediate static pile and accessible PLAY button with no falling or tilt.

The supplied BGM loops after the pour. Native PCM clicks follow the source's
noise/sine envelopes for typing, buttons, and submission. Mute persists. Audio
respects Silent Mode, pauses in the background and Studio, and mixes with other
apps. Native physics and synthesized audio approximate the browser engines;
they do not embed or require the web page.

## Flows

PLAY → six-digit code → name/color → joined room. “Host a game” branches from
the code card to name/color → new room. The existing Rally API and Keychain
membership remain authoritative. Guests become ready on entry, matching the
reference, and can undo readiness. Host start still requires all players ready.

The lobby uses a bounded scrolling list without a player cap. Copy, share,
lock/unlock, remove player, start/reset, and confirmed end/leave remain available.
Studio is available from the landing HUD and room options, and as the main action
after start. Reconnection, server errors, connection settings, and deep links
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
