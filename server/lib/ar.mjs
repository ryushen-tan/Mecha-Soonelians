import { randomInt } from 'node:crypto';

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

export function startAR(room, body, time, random = n => randomInt(n)) {
  if (room.members.length < 2 || !room.members.every(member => member.ready)) {
    fail(409, 'At least two players must be in the room and everyone must be ready.');
  }
  if (room.ar && room.ar.phase !== 'results') fail(409, 'A round is already running.');
  const seeker = room.members[random(room.members.length)];
  room.ar = {
    phase: 'finding', phaseEnds: null,
    hideSeconds: bounded(body.hideSeconds, AR_LIMITS.hide, AR_LIMITS.defaultHide),
    seekSeconds: bounded(body.seekSeconds, AR_LIMITS.seek, AR_LIMITS.defaultSeek),
    seekerID: seeker.id,
    roles: Object.fromEntries(room.members.map(member => [member.id, member.id === seeker.id ? 'seeker' : 'hider'])),
    ready: {}, ghosts: [], startedAt: time
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
    ar.phaseEnds += ar.seekSeconds * 1000;
    if (time >= ar.phaseEnds) ar.phaseEnds = time + ar.seekSeconds * 1000;
  }
  if (ar.phase === 'seeking' && (time >= ar.phaseEnds || (ar.ghosts.length && ar.ghosts.every(ghost => ghost.foundBy)))) {
    ar.phase = 'results';
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

// The host moves the round on early: hiding -> seeking, seeking -> results.
export function skipPhase(room, member, time) {
  const ar = requireAR(room);
  if (!member.host) fail(403, 'Only the host can do that.');
  advanceAR(room, time);
  if (ar.phase === 'hiding') {
    ar.phase = 'seeking';
    ar.phaseEnds = time + ar.seekSeconds * 1000;
  } else if (ar.phase === 'seeking') {
    ar.phase = 'results';
  } else fail(409, 'There is nothing to skip right now.');
}

export function setReady(room, member, ready) {
  const ar = requireAR(room);
  if (typeof ready !== 'boolean') fail(400, 'Ready must be true or false.');
  if (ar.phase === 'finding') ar.ready[member.id] = ready;
}

const requireAR = room => room.ar ?? fail(404, 'No round is running in this room.');

export function validateGhost(ghost, member) {
  const valid = ghost && typeof ghost === 'object' && UUID.test(ghost.id ?? '') && ghost.ownerID === member.id &&
    matrix(ghost.transform) && matrix(ghost.floorTransform) && typeof ghost.flushBack === 'boolean' &&
    typeof ghost.hasModel === 'boolean' && finite(ghost.width) && finite(ghost.height) &&
    ghost.width > 0 && ghost.height > 0 && ghost.width <= 20 && ghost.height <= 20 &&
    (ghost.pose == null || (typeof ghost.pose === 'string' && ghost.pose.length <= 64)) &&
    (!ghost.hasModel || MODEL_FORMATS.includes(ghost.modelFormat));
  if (!valid) fail(400, 'That ghost is not valid.');
}

export function placeGhost(room, member, ghost, time) {
  const ar = requireAR(room);
  advanceAR(room, time);
  if (ar.phase !== 'hiding') fail(409, 'Ghosts can only be placed while hiding.');
  if (ar.roles[member.id] === 'seeker') fail(403, 'The seeker does not hide.');
  validateGhost(ghost, member);
  if (ar.ghosts.some(other => other.id === ghost.id && other.ownerID !== member.id)) fail(409, 'That ghost belongs to someone else.');
  ar.ghosts = ar.ghosts.filter(other => other.ownerID !== member.id);
  ar.ghosts.push({
    id: ghost.id.toLowerCase(), ownerID: member.id, transform: ghost.transform, floorTransform: ghost.floorTransform,
    flushBack: ghost.flushBack, hasModel: ghost.hasModel, modelFormat: ghost.hasModel ? ghost.modelFormat : null,
    paintedBody: ghost.paintedBody === true, pose: ghost.pose ?? null, width: ghost.width, height: ghost.height, foundBy: null
  });
}

export function tagGhost(room, member, ghostID, time) {
  const ar = requireAR(room);
  advanceAR(room, time);
  if (ar.phase !== 'seeking') fail(409, 'Ghosts can only be found while seeking.');
  if (ar.roles[member.id] !== 'seeker') fail(403, 'Only the seeker can find ghosts.');
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
    players: room.members.map(({ id, name, avatar }) => ({
      id, name, avatar, role: ar.roles[id] ?? 'hider', isReady: ar.ready[id] === true
    })),
    ghosts: visibleGhosts(ar, member).map(ghost => ({ ...ghost }))
  };
}

export function canSeeGhost(room, member, ghostID) {
  const ar = requireAR(room);
  return visibleGhosts(ar, member).find(ghost => ghost.id === String(ghostID).toLowerCase()) ?? null;
}
