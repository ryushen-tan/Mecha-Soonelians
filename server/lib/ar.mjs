import { randomInt, randomUUID } from 'node:crypto';

// The online AR hide-and-seek round. One seeker is picked at random; everyone else hides a
// ghost in the scanned house. Phases: finding (everyone relocalizes in the house) -> hiding ->
// seeking -> results. The phone UI used to run this over a local connection; the server now owns
// it, so every action is validated here and every timer is read from the server clock.

const fail = (status, message) => { throw Object.assign(new Error(message), { status }); };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MODEL_FORMATS = ['usdz', 'body'];
const finite = value => Number.isFinite(value);
const matrix = value => Array.isArray(value) && value.length === 16 && value.every(finite);

export const AR_LIMITS = { hide: [60, 600], seek: [60, 900], defaultHide: 300, defaultSeek: 300 };

const bounded = (value, [minimum, maximum], fallback) =>
  Number.isFinite(value) ? Math.round(Math.min(maximum, Math.max(minimum, value))) : fallback;

export const arPaths = {
  house: (roomID, name) => `${roomID}/house/${name}`,
  ghostImage: (roomID, memberID, ghostID) => `${roomID}/ghosts/${memberID}/${ghostID}.png`,
  ghostModel: (roomID, memberID, ghostID, format) => `${roomID}/ghosts/${memberID}/${ghostID}.${format}`
};
export const HOUSE_FILES = { structure: 'structure.json', worldmap: 'worldmap.arexperience' };

// Which house the round is in. "bundled": every phone already has the same scan inside the app, so
// nothing is uploaded or downloaded and the id says which scan. "uploaded": the host sent their own.
export function houseRef(house) {
  if (house == null) return { kind: 'uploaded', id: null };
  if (house.kind === 'bundled' && typeof house.id === 'string' && /^[0-9a-f]{8,64}$/i.test(house.id)) {
    return { kind: 'bundled', id: house.id.toLowerCase() };
  }
  fail(400, 'That house is not valid.');
}

export function startAR(room, body, time, random = n => randomInt(n)) {
  if (room.members.length < 2 || !room.members.every(member => member.ready)) {
    fail(409, 'At least two players must be in the room and everyone must be ready.');
  }
  if (room.ar && room.ar.phase !== 'results') fail(409, 'A round is already running.');
  const seeker = room.members[random(room.members.length)];
  // Carry the completed round forward once, inside the same persisted room transaction.
  // Keep round points separate so winners and the blue +points label stay round-specific.
  const previous = room.ar;
  const scoreTotals = Object.fromEntries(room.members.map(member => [member.id,
    previous ? totalPoints(previous, member.id) : 0]));
  room.ar = {
    phase: 'finding', phaseEnds: null,
    scoreTotals, roundNumber: (previous?.roundNumber ?? (previous ? 1 : 0)) + 1,
    hideSeconds: bounded(body.hideSeconds, AR_LIMITS.hide, AR_LIMITS.defaultHide),
    seekSeconds: bounded(body.seekSeconds, AR_LIMITS.seek, AR_LIMITS.defaultSeek),
    seekerID: seeker.id,
    roles: Object.fromEntries(room.members.map(member => [member.id, member.id === seeker.id ? 'seeker' : 'hider'])),
    ready: {}, ghosts: [], startedAt: time, house: houseRef(body.house)
  };
  room.status = 'started';
  room.locked = true;
  return room.ar;
}

export function clearAR(room) {
  room.ar = null;
}

// Keeps the round consistent with who is in the room, then moves the clock forward.
export function advanceAR(room, time) {
  const ar = room.ar;
  if (!ar) return;
  const ids = new Set(room.members.map(member => member.id));
  ar.ghosts = ar.ghosts.filter(ghost => ids.has(ghost.ownerID));
  for (const id of Object.keys(ar.roles)) if (!ids.has(id)) { delete ar.roles[id]; delete ar.ready[id]; }
  for (const member of room.members) if (!ar.roles[member.id]) ar.roles[member.id] = 'hider';
  if (!ids.has(ar.seekerID)) {
    // The seeker left: someone else takes over, and their own ghost (if any) is dropped.
    const next = room.members[randomInt(room.members.length)];
    ar.seekerID = next.id;
    for (const id of Object.keys(ar.roles)) ar.roles[id] = id === next.id ? 'seeker' : 'hider';
    ar.ghosts = ar.ghosts.filter(ghost => ghost.ownerID !== next.id);
  }
  if (ar.phase === 'finding' && room.members.length >= 2 && room.members.every(member => ar.ready[member.id])) {
    beginHiding(ar, time);
  }
  if (ar.phase === 'hiding' && time >= ar.phaseEnds) {
    ar.phase = 'seeking';
    ar.seekingStarted = ar.phaseEnds;
    ar.phaseEnds += ar.seekSeconds * 1000;
    if (time >= ar.phaseEnds) ar.phaseEnds = time + ar.seekSeconds * 1000;
  }
  if (ar.phase === 'seeking' && (time >= ar.phaseEnds || (ar.ghosts.length && ar.ghosts.every(ghost => ghost.foundBy)))) {
    ar.phase = 'results';
    decideWinner(room);
  }
}

function beginHiding(ar, time) {
  ar.phase = 'hiding';
  ar.phaseEnds = time + ar.hideSeconds * 1000;
}

export function beginRound(room, member, time) {
  const ar = requireAR(room);
  if (!member.host) fail(403, 'Only the host can start the round.');
  if (ar.phase !== 'finding') fail(409, 'The round has already started.');
  beginHiding(ar, time);
}

// Chirps: a hider makes their ghost chirp so the seeker can follow the sound. Only while seeking,
// only an unfound hider, at most once per CHIRP_COOLDOWN. The seeker's phone plays each chirp once,
// from the ghost's spot in the house.
export const CHIRP_COOLDOWN = 8_000;
const CHIRP_VISIBLE = 10_000;

export function chirp(room, member, time) {
  const ar = requireAR(room);
  advanceAR(room, time);
  if (ar.phase !== 'seeking') fail(409, 'You can only chirp while the seeker is looking.');
  if (ar.roles[member.id] === 'seeker') fail(403, 'Only hiders can chirp.');
  const ghost = ar.ghosts.find(item => item.ownerID === member.id);
  if (!ghost) fail(409, 'Hide your ghost first.');
  if (ghost.foundBy) fail(409, 'You have already been found.');
  ar.chirps = (ar.chirps ?? []).filter(item => time - item.at < CHIRP_VISIBLE);
  const last = ar.chirps.findLast(item => item.ownerID === member.id);
  if (last && time - last.at < CHIRP_COOLDOWN) fail(429, 'Wait a moment before chirping again.');
  ar.chirps.push({ id: randomUUID(), ownerID: member.id, ghostID: ghost.id, at: time });
}

// Points: a hider scores while the seeker's camera has their (unfound) ghost in view: bold hiding
// pays. The seeker's phone reports which ghosts are on screen and not behind a wall about once a
// second; each report counts the time since the last one, capped so a dropped report can't be
// claimed later. If anyone is still hidden at the end, the hider with the most points wins.
export const POINTS_PER_SECOND = 10;
const SEEN_CAP = 1_500;
const SEEN_NOW = 2_500;

export function reportSeen(room, member, ghostIDs, time) {
  const ar = requireAR(room);
  advanceAR(room, time);
  if (ar.phase !== 'seeking') return;
  if (ar.roles[member.id] !== 'seeker') fail(403, 'Only the seeker reports what they see.');
  if (!Array.isArray(ghostIDs) || ghostIDs.length > 50) fail(400, 'Send the ghosts you can see.');
  const elapsed = Math.max(0, Math.min(SEEN_CAP, time - (ar.lastSeenReport ?? time)));
  ar.lastSeenReport = time;
  ar.exposure ??= {};
  ar.lastSeen ??= {};
  const ids = new Set(ghostIDs.map(id => String(id).toLowerCase()));
  for (const ghost of ar.ghosts) {
    if (!ids.has(ghost.id) || ghost.foundBy) continue;
    ar.exposure[ghost.ownerID] = (ar.exposure[ghost.ownerID] ?? 0) + elapsed;
    ar.lastSeen[ghost.ownerID] = time;
  }
}

const points = (ar, id) => Math.floor((ar.exposure?.[id] ?? 0) / 1000) * POINTS_PER_SECOND;
const totalPoints = (ar, id) => (ar.scoreTotals?.[id] ?? 0) + points(ar, id);

// Decided when the round ends: the seeker if everyone was found; otherwise the hidden hider(s) with
// the most points.
function decideWinner(room) {
  const ar = room.ar;
  const hidden = ar.ghosts.filter(ghost => !ghost.foundBy).map(ghost => ghost.ownerID);
  if (!ar.ghosts.length) ar.winnerIDs = [];
  else if (!hidden.length) ar.winnerIDs = [ar.seekerID];
  else {
    const best = Math.max(...hidden.map(id => points(ar, id)));
    ar.winnerIDs = hidden.filter(id => points(ar, id) === best);
  }
}

// The host moves the round on early: hiding -> seeking, seeking -> results.
export function skipPhase(room, member, time) {
  const ar = requireAR(room);
  if (!member.host) fail(403, 'Only the host can do that.');
  advanceAR(room, time);
  if (ar.phase === 'hiding') {
    ar.phase = 'seeking';
    ar.seekingStarted = time;
    ar.phaseEnds = time + ar.seekSeconds * 1000;
  } else if (ar.phase === 'seeking') {
    ar.phase = 'results';
    decideWinner(room);
  } else fail(409, 'There is nothing to skip right now.');
}

export function setReady(room, member, ready) {
  const ar = requireAR(room);
  if (typeof ready !== 'boolean') fail(400, 'Ready must be true or false.');
  if (ar.phase === 'finding') ar.ready[member.id] = ready;
}

const requireAR = room => room.ar ?? fail(404, 'No round is running in this room.');

export function validateGhost(ghost, member) {
  const valid = ghost && typeof ghost === 'object' && UUID.test(ghost.id ?? '') && String(ghost.ownerID).toLowerCase() === member.id &&
    matrix(ghost.transform) && matrix(ghost.floorTransform) && typeof ghost.flushBack === 'boolean' &&
    typeof ghost.hasModel === 'boolean' && finite(ghost.width) && finite(ghost.height) &&
    ghost.width > 0 && ghost.height > 0 && ghost.width <= 20 && ghost.height <= 20 &&
    (ghost.pose == null || (typeof ghost.pose === 'string' && ghost.pose.length <= 64)) &&
    (!ghost.hasModel || MODEL_FORMATS.includes(ghost.modelFormat));
  if (!valid) fail(400, 'That ghost is not valid.');
}

// A hide that began while hiding (its upload links were issued then) still counts if hiding ends
// while its files upload, so a slow connection or the host skipping ahead never loses a ghost.
export const PLACE_GRACE = 120_000;
// And a hide pressed just as hiding ended (the timer ran out, or the host skipped ahead) still starts.
export const LATE_HIDE = 30_000;

export function beginUpload(room, member, ghostID, time) {
  const ar = requireAR(room);
  advanceAR(room, time);
  const justEnded = ar.phase === 'seeking' && ar.seekingStarted != null && time - ar.seekingStarted < LATE_HIDE;
  if (ar.phase !== 'hiding' && !justEnded) fail(409, 'Hiding is over, so you can no longer place a ghost.');
  if (ar.roles[member.id] === 'seeker') fail(403, 'The seeker does not hide.');
  ar.pending ??= {};
  ar.pending[member.id] = { id: String(ghostID).toLowerCase(), at: time };
}

export function placeGhost(room, member, ghost, time) {
  const ar = requireAR(room);
  advanceAR(room, time);
  const pending = ar.pending?.[member.id];
  const late = ar.phase === 'seeking' && pending && pending.id === String(ghost?.id).toLowerCase() && time - pending.at < PLACE_GRACE;
  if (ar.phase !== 'hiding' && !late) fail(409, 'Hiding is over, so you can no longer place a ghost.');
  if (ar.roles[member.id] === 'seeker') fail(403, 'The seeker does not hide.');
  validateGhost(ghost, member);
  if (ar.ghosts.some(other => other.id === ghost.id.toLowerCase() && other.ownerID !== member.id)) fail(409, 'That ghost belongs to someone else.');
  ar.ghosts = ar.ghosts.filter(other => other.ownerID !== member.id);
  ar.ghosts.push({
    id: ghost.id.toLowerCase(), ownerID: member.id, transform: ghost.transform, floorTransform: ghost.floorTransform,
    flushBack: ghost.flushBack, hasModel: ghost.hasModel, modelFormat: ghost.hasModel ? ghost.modelFormat : null,
    paintedBody: ghost.paintedBody === true, pose: ghost.pose ?? null, width: ghost.width, height: ghost.height, foundBy: null
  });
  if (ar.pending) delete ar.pending[member.id];
}

export function tagGhost(room, member, ghostID, time) {
  const ar = requireAR(room);
  advanceAR(room, time);
  if (ar.roles[member.id] !== 'seeker') fail(403, 'Only the seeker can find ghosts.');
  // A second tap on the last ghost arrives after the round has ended: nothing left to do.
  if (ar.phase === 'results') return;
  if (ar.phase !== 'seeking') fail(409, 'Ghosts can only be found while seeking.');
  const ghost = ar.ghosts.find(item => item.id === String(ghostID).toLowerCase());
  if (!ghost) fail(404, 'That ghost is not here.');
  if (!ghost.foundBy) ghost.foundBy = member.id;
  advanceAR(room, time);
}

// Hiders see their own ghost; the seeker sees everyone's while seeking; everyone sees all at the end.
export function visibleGhosts(ar, member) {
  switch (ar.phase) {
    case 'hiding': return ar.ghosts.filter(ghost => ghost.ownerID === member.id);
    case 'seeking': return ar.roles[member.id] === 'seeker' ? ar.ghosts : ar.ghosts.filter(ghost => ghost.ownerID === member.id);
    case 'results': return ar.ghosts;
    default: return [];
  }
}

// The same shape the phone's GameState decodes (phase `lobby` is the finding-the-house phase).
export function snapshotAR(room, member, time) {
  advanceAR(room, time);
  const ar = room.ar;
  if (!ar) return null;
  const phase = ar.phase === 'finding' ? 'lobby' : ar.phase;
  return {
    phase, secondsLeft: ar.phaseEnds ? Math.max(0, Math.ceil((ar.phaseEnds - time) / 1000)) : 0,
    hideSeconds: ar.hideSeconds, seekSeconds: ar.seekSeconds, seekerID: ar.seekerID, startedAt: ar.startedAt,
    roundNumber: ar.roundNumber ?? 1,
    house: ar.house ?? { kind: 'uploaded', id: null },
    players: room.members.map(({ id, name, avatar }) => ({
      id, name, avatar, role: ar.roles[id] ?? 'hider', isReady: ar.ready[id] === true,
      points: points(ar, id), totalPoints: totalPoints(ar, id),
      // Only a hider learns that the seeker is looking at them right now.
      seenNow: ar.phase === 'seeking' && id === member.id && time - (ar.lastSeen?.[id] ?? -Infinity) < SEEN_NOW
    })),
    winnerIDs: ar.phase === 'results' ? ar.winnerIDs ?? [] : [],
    ghosts: visibleGhosts(ar, member).map(ghost => ({ ...ghost })),
    // The seeker hears every recent chirp; a hider sees only their own, for its cooldown.
    chirps: (ar.chirps ?? [])
      .filter(item => time - item.at < CHIRP_VISIBLE && ar.phase === 'seeking' &&
        (ar.roles[member.id] === 'seeker' || item.ownerID === member.id))
      .map(({ id, ghostID, ownerID, at }) => ({ id, ghostID, ownerID, age: time - at }))
  };
}

export function canSeeGhost(room, member, ghostID) {
  const ar = requireAR(room);
  return visibleGhosts(ar, member).find(ghost => ghost.id === String(ghostID).toLowerCase()) ?? null;
}
