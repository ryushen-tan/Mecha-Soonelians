import { createHash } from 'node:crypto';

const fail = (status, message) => { throw Object.assign(new Error(message), { status }); };
const MODES = ['basic', 'infection', 'double', 'chicken'];
const vector = value => Array.isArray(value) && value.length === 3 && value.every(number => Number.isFinite(number) && Math.abs(number) <= 100);
const bounded = (value, minimum, maximum, fallback) => Number.isFinite(value) ? Math.min(maximum, Math.max(minimum, value)) : fallback;
export const defaultSurfaces = [
  { id: 'back-wall', kind: 'wall', dimensions: [6, 3, 0.12], position: [0, 1.5, 2.8] },
  { id: 'left-wall', kind: 'wall', dimensions: [0.12, 3, 6], position: [-3, 1.5, 0] },
  { id: 'cabinet', kind: 'object', dimensions: [1.2, 0.85, 0.6], position: [1.5, 0.425, 2.35] },
  { id: 'sofa', kind: 'object', dimensions: [1.8, 0.65, 0.8], position: [-2.25, 0.325, 1.6] }
];

export function rayBox(origin, direction, box) {
  let near = 0, far = Infinity;
  for (let axis = 0; axis < 3; axis++) {
    if (Math.abs(direction[axis]) < 1e-9) {
      if (origin[axis] < box.min[axis] || origin[axis] > box.max[axis]) return Infinity;
    } else {
      const first = (box.min[axis] - origin[axis]) / direction[axis];
      const second = (box.max[axis] - origin[axis]) / direction[axis];
      near = Math.max(near, Math.min(first, second));
      far = Math.min(far, Math.max(first, second));
      if (far < near) return Infinity;
    }
  }
  return near;
}

function obstacleDistance(origin, direction, surface) {
  if (['decoration', 'window'].includes(surface.kind)) return Infinity;
  const localOrigin = [], localDirection = [];
  if (surface.transform?.length === 16) {
    const matrix = surface.transform;
    const delta = origin.map((value, axis) => value - matrix[12 + axis]);
    for (let axis = 0; axis < 3; axis++) {
      const column = matrix.slice(axis * 4, axis * 4 + 3);
      const lengthSquared = column.reduce((total, value) => total + value * value, 0);
      if (lengthSquared < 0.0001) return Infinity;
      localOrigin.push(delta.reduce((total, value, index) => total + value * column[index], 0) / lengthSquared);
      localDirection.push(direction.reduce((total, value, index) => total + value * column[index], 0) / lengthSquared);
    }
  } else {
    localOrigin.push(...origin.map((value, axis) => value - (surface.position?.[axis] ?? 0)));
    localDirection.push(...direction);
  }
  const halves = surface.dimensions.map(value => Math.max(0.035, Math.abs(value)) / 2);
  const distance = rayBox(localOrigin, localDirection, { min: halves.map(value => -value), max: halves });
  if (Number.isFinite(distance) && surface.holes?.some(hole => {
    const horizontal = localOrigin[0] + localDirection[0] * distance;
    const vertical = localOrigin[1] + localDirection[1] * distance;
    return Math.abs(horizontal - hole[0]) < hole[2] / 2 && Math.abs(vertical - hole[1]) < hole[3] / 2;
  })) return Infinity;
  return distance;
}

export function acceptDisguise(room, member, data) {
  if (data.length < 20 || data.length > 20 * 1024 * 1024 || data.toString('ascii', 0, 4) !== 'glTF' || data.readUInt32LE(4) !== 2 || data.readUInt32LE(8) !== data.length) fail(400, 'Send a GLB 2.0 disguise smaller than 20 MB.');
  let json;
  try { json = JSON.parse(data.subarray(20, 20 + data.readUInt32LE(12))); } catch { fail(400, 'The disguise GLB is invalid.'); }
  if ([...(json.images ?? []), ...(json.buffers ?? [])].some(item => item.uri && !item.uri.startsWith('data:'))) fail(400, 'Disguises must contain their own textures and geometry.');
  const boxes = json.nodes?.find(node => Array.isArray(node.extras?.disguises))?.extras.disguises;
  if (!boxes?.length || boxes.length > 3 || boxes.some(box => !vector(box.min) || !vector(box.max) || box.min.some((value, axis) => value >= box.max[axis] || box.max[axis] - value > 5))) fail(400, 'The disguise has invalid body or clone bounds.');
  if (room.game?.phase === 'hunting' && room.game.found[member.id] && ['basic', 'infection'].includes(room.game.mode)) fail(409, 'This disguise was already found.');
  if (room.game?.phase === 'hunting' && ['hunter', 'dual'].includes(room.game.roles[member.id])) fail(409, 'Hunters keep their published disguise locked during the hunt.');
  room.disguises ??= new Map();
  const version = createHash('sha256').update(data).digest('hex');
  room.disguises.set(member.id, { data, boxes, version });
  return version;
}

export function startGame(room, body, time) {
  if (room.members.length < 2 || !room.members.every(member => member.ready)) fail(409, 'At least two ready players are required.');
  if (!MODES.includes(body.mode)) fail(400, 'Choose Basic, Infection, Double or Chicken race.');
  const mode = body.mode;
  const hunter = room.members.find(member => member.id === body.hunterID) ?? room.members[0];
  const hiders = room.members.filter(member => ['double', 'chicken'].includes(mode) || member.id !== hunter.id);
  if (hiders.some(member => !room.disguises?.has(member.id))) fail(409, 'Every hider must publish a 3D disguise before the round starts.');
  const surfaces = body.room?.surfaces;
  if (surfaces && (!Array.isArray(surfaces) || surfaces.length > 1500 || surfaces.some(surface => !vector(surface.dimensions) || surface.dimensions.some(value => value < 0) ||
      (surface.transform && (surface.transform.length !== 16 || !surface.transform.every(Number.isFinite))) ||
      (surface.position && !vector(surface.position)) || (surface.holes && (!Array.isArray(surface.holes) || surface.holes.some(hole => !Array.isArray(hole) || hole.length !== 4 || !hole.every(Number.isFinite))))))) fail(400, 'Invalid room geometry.');
  const preparation = bounded(body.preparationSeconds, 0, 600, 60);
  const hunting = bounded(body.huntSeconds, 10, 1800, 180);
  room.game = { mode, phase: 'preparation', phaseEnds: time + preparation * 1000, huntSeconds: hunting,
    autoTauntSeconds: body.autoTauntSeconds === 0 ? 0 : bounded(body.autoTauntSeconds, 10, 120, 30),
    roles: Object.fromEntries(room.members.map(member => [member.id, ['double', 'chicken'].includes(mode) ? 'dual' : member.id === hunter.id ? 'hunter' : 'hider'])),
    found: {}, scores: Object.fromEntries(room.members.map(member => [member.id, 0])), finds: {}, shots: {}, taunts: [], lastHint: time,
    views: {}, exposure: {}, lastExposure: time,
    targets: hiders.map(member => member.id), targetIndex: 0, targetSeconds: Math.max(10, hunting / Math.max(hiders.length, 1)),
    surfaces: surfaces ?? defaultSurfaces, roomName: typeof body.room?.name === 'string' ? body.room.name.slice(0, 80) : 'Shared room',
    roomSource: body.room?.source === 'roomplan' ? 'roomplan' : 'practice', winner: null };
  room.status = 'started';
  return room.game;
}

export function advanceGame(room, time) {
  const game = room.game;
  if (!game || game.phase === 'finished') return;
  const members = new Set(room.members.map(member => member.id));
  game.targets = game.targets.filter(id => members.has(id));
  if (game.phase === 'preparation' && time >= game.phaseEnds) {
    game.phase = 'hunting'; game.phaseEnds += game.huntSeconds * 1000;
    game.targetEnds = time + game.targetSeconds * 1000;
    game.lastExposure = time;
  }
  if (game.phase !== 'hunting') return;
  scoreExposure(room, time);
  const survivors = game.targets.filter(id => !game.found[id]);
  if (time >= game.phaseEnds || (['basic', 'infection'].includes(game.mode) && survivors.length === 0) || game.targets.length === 0) {
    game.phase = 'finished';
    if (['basic', 'infection'].includes(game.mode)) game.winner = survivors.length ? 'hiders' : 'hunters';
    else {
      const best = Math.max(0, ...room.members.map(member => game.scores[member.id] ?? 0));
      game.winner = room.members.filter(member => game.scores[member.id] === best).map(member => member.name).join(', ');
    }
    return;
  }
  if (game.mode === 'chicken' && time >= game.targetEnds) {
    game.targetIndex++;
    if (game.targetIndex >= game.targets.length) { game.phaseEnds = time; advanceGame(room, time); return; }
    game.targetEnds = time + game.targetSeconds * 1000;
  }
  if (game.autoTauntSeconds && time - game.lastHint >= game.autoTauntSeconds * 1000) {
    for (const id of survivors) recordTaunt(room, id, time);
    game.lastHint = time;
  }
  game.taunts = game.taunts.filter(taunt => time - taunt.at < 5000);
}

function scoreExposure(room, time) {
  const game = room.game;
  const elapsed = Math.max(0, Math.min(2000, time - game.lastExposure));
  game.lastExposure = time;
  if (!elapsed) return;
  const targets = game.mode === 'chicken' ? [game.targets[game.targetIndex]] : game.targets;
  for (const id of targets) {
    if (!id || game.found[id]) continue;
    const seen = Object.entries(game.views).some(([hunter, view]) => {
      if (hunter === id || time - view.at > 2500 || !['hunter', 'dual'].includes(game.roles[hunter]) || game.finds[hunter]?.includes(id)) return false;
      const forward = view.direction;
      const rightLength = Math.hypot(forward[0], forward[2]);
      if (rightLength < 0.01) return false;
      const right = [-forward[2] / rightLength, 0, forward[0] / rightLength];
      const up = [right[1] * forward[2] - right[2] * forward[1], right[2] * forward[0] - right[0] * forward[2], right[0] * forward[1] - right[1] * forward[0]];
      const tangent = Math.tan(view.fov * Math.PI / 360);
      return (room.disguises?.get(id)?.boxes ?? []).some(box => {
        const center = box.min.map((value, axis) => (value + box.max[axis]) / 2);
        const points = [center, ...Array.from({ length: 8 }, (_, corner) => box.min.map((value, axis) => corner & (1 << axis) ? box.max[axis] : value))];
        return points.some(point => {
          const delta = point.map((value, axis) => value - view.origin[axis]);
          const dot = axis => delta.reduce((total, value, index) => total + value * axis[index], 0);
          const depth = dot(forward), distance = Math.hypot(...delta);
          if (depth < 0.05 || Math.abs(dot(right)) > depth * tangent * view.aspect || Math.abs(dot(up)) > depth * tangent) return false;
          const direction = delta.map(value => value / distance);
          return !game.surfaces.some(surface => obstacleDistance(view.origin, direction, surface) < distance - 0.03);
        });
      });
    });
    if (seen) {
      game.exposure[id] = (game.exposure[id] ?? 0) + elapsed;
      const seconds = Math.floor(game.exposure[id] / 1000);
      game.exposure[id] -= seconds * 1000;
      game.scores[id] = (game.scores[id] ?? 0) + seconds * 10;
    }
  }
}

export function recordView(room, member, body, time) {
  advanceGame(room, time);
  const game = room.game;
  if (!game || game.phase !== 'hunting') return;
  if (!['hunter', 'dual'].includes(game.roles[member.id])) fail(403, 'Only hunters report their view.');
  if (!vector(body.origin) || !vector(body.direction) || Math.abs(Math.hypot(...body.direction) - 1) > 0.01 || !Number.isFinite(body.fov) || !Number.isFinite(body.aspect)) fail(400, 'Invalid camera view.');
  game.views[member.id] = { origin: body.origin, direction: body.direction, fov: bounded(body.fov, 20, 100, 38), aspect: bounded(body.aspect, 0.25, 4, 1), at: time };
}

export function visibleOwners(room, member, time) {
  advanceGame(room, time);
  const game = room.game;
  if (!game || game.phase === 'finished') return [...(room.disguises?.keys() ?? [])];
  if (game.phase === 'preparation') return game.mode === 'basic' && game.roles[member.id] === 'hider'
    ? game.targets : [member.id];
  if (game.mode === 'chicken') return [member.id, game.targets[game.targetIndex]].filter(Boolean);
  if (game.mode === 'infection' && game.roles[member.id] === 'hider') return [member.id];
  return game.targets.filter(id => !game.found[id]);
}

export function snapshotGame(room, member, time) {
  advanceGame(room, time);
  const game = room.game;
  const visible = member ? visibleOwners(room, member, time) : [];
  return {
    mode: game?.mode ?? 'basic', phase: game?.phase ?? 'lobby', remaining: game ? Math.max(0, Math.ceil((game.phaseEnds - time) / 1000)) : 0,
    role: game?.roles[member?.id] ?? 'unassigned', winner: game?.winner ?? null,
    targetID: game?.mode === 'chicken' && game.phase === 'hunting' ? game.targets[game.targetIndex] ?? null : null,
    published: room.members.filter(player => room.disguises?.has(player.id)).map(player => player.id),
    visible: visible.filter(id => room.disguises?.has(id)).map(id => ({ id, version: room.disguises.get(id).version })),
    scores: room.members.map(player => ({ id: player.id, name: player.name, points: game?.scores[player.id] ?? 0, found: game?.found[player.id] ?? false })),
    taunts: game?.phase === 'hunting' ? game.taunts : [],
    room: game ? { name: game.roomName, source: game.roomSource, surfaces: game.surfaces } : null
  };
}

function recordTaunt(room, id, time) {
  const box = room.disguises?.get(id)?.boxes[0];
  if (box) room.game.taunts.push({ id, at: time, position: box.min.map((value, axis) => (value + box.max[axis]) / 2) });
}

export function taunt(room, member, time) {
  advanceGame(room, time);
  const game = room.game;
  if (!game || game.phase !== 'hunting' || game.roles[member.id] === 'hunter' || game.found[member.id]) fail(409, 'Only a hiding player can taunt during the hunt.');
  const previous = game.taunts.findLast(taunt => taunt.id === member.id);
  if (previous && time - previous.at < 3000) fail(429, 'Wait before whistling again.');
  recordTaunt(room, member.id, time);
}

export function shoot(room, member, body, time) {
  advanceGame(room, time);
  const game = room.game;
  if (!game || game.phase !== 'hunting' || !['hunter', 'dual'].includes(game.roles[member.id])) fail(403, 'Hunters can tag disguises after preparation ends.');
  if (!vector(body.origin) || !vector(body.direction)) fail(400, 'Send a finite aiming ray.');
  const length = Math.hypot(...body.direction);
  if (length < 0.9 || length > 1.1) fail(400, 'The aiming direction must be normalized.');
  if (time - (game.shots[member.id] ?? -Infinity) < 800) fail(429, 'Wait for the next tag.');
  game.shots[member.id] = time;
  if (body.targetID == null) return { hit: false, targetID: null };
  if (typeof body.targetID !== 'string' || body.targetID.length > 100) fail(400, 'Invalid target identity.');
  const direction = body.direction.map(value => value / length);
  const visible = new Set(visibleOwners(room, member, time));
  let target, distance = Infinity;
  for (const id of game.targets) {
    if (id !== body.targetID || id === member.id || !visible.has(id) || game.found[id] || game.finds[member.id]?.includes(id)) continue;
    for (const box of room.disguises.get(id)?.boxes ?? []) {
      const hit = rayBox(body.origin, direction, box);
      if (hit < distance) { distance = hit; target = id; }
    }
  }
  if (!target || game.surfaces.some(surface => obstacleDistance(body.origin, direction, surface) < distance - 0.03)) return { hit: false, targetID: null };
  game.scores[member.id] = (game.scores[member.id] ?? 0) + 500;
  (game.finds[member.id] ??= []).push(target);
  if (['basic', 'infection'].includes(game.mode)) game.found[target] = true;
  if (game.mode === 'infection') game.roles[target] = 'hunter';
  advanceGame(room, time);
  return { hit: true, targetID: target };
}
