import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { acceptDisguise, snapshotGame, visibleOwners, startGame, shoot, taunt, recordView, emergencyEject } from './game.mjs';
import { createMemoryRoomStore } from './room-store.mjs';

const LIMIT = 4096;
const UPLOAD = 20 * 1024 * 1024;
const fail = (status, message) => { throw Object.assign(new Error(message), { status }); };
// Tokens are 256-bit random values, so a plain SHA-256 is enough to make stored hashes useless to a reader.
export const hashToken = token => createHash('sha256').update(token).digest('hex');

// Rooms live in a store shared by every server instance (Supabase in production). The store
// runs each request's room logic while holding that room's lock, so the synchronous logic
// below always reads and changes one consistent room at a time.
export function createLobbyHandler({ now = Date.now, idleTTL = 2 * 60 * 60 * 1000,
  memberTTL = 90_000, maxRooms = 1000, rateLimit = 180, maxUploading = 256 * 1024 * 1024,
  store = createMemoryRoomStore() } = {}) {
  // Abuse limits are per instance; they are not room state.
  const rates = new Map();
  let uploading = 0;

  function limit(key) {
    const rate = rates.get(key) ?? { count: 0, until: now() + 60_000 };
    rates.set(key, rate);
    if (++rate.count > rateLimit) fail(429, 'Too many attempts. Wait a minute and try again.');
  }

  function removeMember(room, id) {
    room.members = room.members.filter(m => m.id !== id);
    room.disguises?.delete(id);
  }

  // Expires inactive guests; returns false when the host expired or the room went idle.
  function prune(room, time) {
    const host = room.members.find(m => m.host);
    if (!host || time - room.touchedAt > idleTTL || time - host.seenAt > memberTTL) {
      room.closed = true;
      return false;
    }
    for (const m of room.members) if (!m.host && time - m.seenAt > memberTTL) removeMember(room, m.id);
    return true;
  }

  function snapshot(room, member) {
    return {
      code: room.code, locked: room.locked,
      status: room.status, createdAt: room.createdAt,
      members: room.members.map(({ id, name, avatar, host, ready, hasCharacter }) => ({ id, name, avatar, host, ready, hasCharacter })),
      game: snapshotGame(room, member, now())
    };
  }

  function profile(body) {
    const name = typeof body.name === 'string' ? body.name.trim() : '';
    if (!name || [...name].length > 20 || /[\p{Cc}\p{Cf}]/u.test(name)) {
      fail(400, 'Choose a name between 1 and 20 characters.');
    }
    if (!Number.isInteger(body.avatar) || body.avatar < 0 || body.avatar > 5) {
      fail(400, 'Choose one of the six avatars.');
    }
    return { name, avatar: body.avatar };
  }

  function addMember(room, body, host) {
    const details = profile(body);
    const nameKey = details.name.toLocaleLowerCase('en-US');
    if (room.members.some(m => m.name.toLocaleLowerCase('en-US') === nameKey)) {
      fail(409, 'That name is taken in this room. Try another.');
    }
    const token = randomBytes(32).toString('hex');
    const member = { ...details, nameKey, id: randomUUID(), tokenHash: hashToken(token),
      host, hasCharacter: body.hasCharacter === true, ready: room.requiresCharacter ? false : host, seenAt: now() };
    room.members.push(member);
    room.touchedAt = now();
    return { room: snapshot(room), memberID: member.id, token };
  }

  function enter(room) {
    if (!room || !prune(room, now())) fail(404, 'Room not found. Check the code or ask the host for a new one.');
    return room;
  }

  function authenticate(room, token) {
    const tokenHash = hashToken(token ?? '');
    const member = room.members.find(m => m.tokenHash === tokenHash);
    if (!member) fail(401, 'You are no longer in this room. Join again with the room code.');
    member.seenAt = now();
    room.touchedAt = now();
    return member;
  }

  async function readBody(req, limit = LIMIT) {
    let size = 0;
    const chunks = [];
    for await (const chunk of req) {
      size += chunk.length;
      if (size > limit) fail(413, 'Request is too large.');
      chunks.push(chunk);
    }
    try {
      const value = JSON.parse(Buffer.concat(chunks).toString() || '{}');
      if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error();
      return value;
    } catch { fail(400, 'Send a valid JSON object.'); }
  }

  // Everything except creating a room and publishing a disguise. Runs under the room lock.
  // Returns [status, json] or, for a disguise download, [200, null, blob].
  function act(room, req, body, action, disguiseID, targetID, token) {
    enter(room);
    if (req.method === 'POST' && action === 'join') {
      if (room.status !== 'waiting') fail(409, 'This session has already started.');
      if (room.locked) fail(409, 'This room is locked. Ask the host to unlock it.');
      return [201, addMember(room, body, false)];
    }
    const member = authenticate(room, token);
    if (req.method === 'GET' && !action) return [200, { room: snapshot(room, member) }];
    if (action === 'game') {
      if (req.method === 'GET') return [200, { game: snapshotGame(room, member, now()) }];
      if (req.method !== 'POST') fail(405, 'Unsupported game action.');
      let result;
      if (body.action === 'start') {
        if (!member.host) fail(403, 'Only the host can start a round.');
        if (room.game && room.game.phase !== 'finished') fail(409, 'A round is already running.');
        if (room.requiresCharacter && !room.members.every(m => m.hasCharacter)) fail(409, 'Everyone needs a character before starting.');
        startGame(room, body, now());
      } else if (body.action === 'shoot') result = shoot(room, member, body, now());
      else if (body.action === 'taunt') taunt(room, member, now());
      else if (body.action === 'view') recordView(room, member, body, now());
      else if (body.action === 'eject') result = emergencyEject(room, member, now());
      else fail(400, 'Choose a supported game action.');
      return [200, { game: snapshotGame(room, member, now()), result: result ?? null }];
    }
    if (action?.startsWith('disguise')) {
      if (req.method !== 'GET' || !disguiseID) fail(405, 'Unsupported disguise action.');
      if (!visibleOwners(room, member, now()).includes(disguiseID)) fail(403, 'That disguise is hidden in this phase or game mode.');
      const disguise = room.disguises?.get(disguiseID);
      if (!disguise) fail(404, 'Disguise not published.');
      return [200, null, disguise.blob];
    }
    if (req.method === 'POST' && action === 'leave') {
      if (member.host) room.closed = true;
      else removeMember(room, member.id);
      return [200, { ok: true }];
    }
    if (req.method === 'PATCH' && action === 'me') {
      if (typeof body.ready !== 'boolean') fail(400, 'Ready must be true or false.');
      if ('hasCharacter' in body && typeof body.hasCharacter !== 'boolean') fail(400, 'Character availability must be true or false.');
      if (room.status !== 'waiting') fail(409, 'The session has already started.');
      const hasCharacter = body.hasCharacter ?? member.hasCharacter;
      if (room.requiresCharacter) {
        if (body.ready && !hasCharacter) fail(409, 'Choose a character before getting ready.');
        if (body.ready && !room.disguises?.has(member.id)) fail(409, 'Prepare your character before getting ready.');
        member.ready = body.ready;
      } else if (!member.host) member.ready = body.ready;
      member.hasCharacter = hasCharacter;
      return [200, { room: snapshot(room) }];
    }
    if (!member.host) fail(403, 'Only the host can change the room.');
    if (req.method === 'DELETE' && targetID) {
      if (targetID === member.id) fail(400, 'Use End room to leave as the host.');
      if (!room.members.some(m => m.id === targetID)) fail(409, 'That player has already left.');
      removeMember(room, targetID);
      return [200, { room: snapshot(room) }];
    }
    if (req.method === 'PATCH' && !action) {
      if ('locked' in body) {
        if (typeof body.locked !== 'boolean') fail(400, 'Locked must be true or false.');
        room.locked = body.locked;
      } else if (body.status === 'started') {
        if (room.status !== 'waiting') fail(409, 'This session has already started.');
        if (room.requiresCharacter && !room.members.every(m => m.hasCharacter)) fail(409, 'Everyone needs a character before starting.');
        if (room.members.length < 2 || !room.members.every(m => m.ready)) {
          fail(409, 'At least two players must be in the room and everyone must be ready.');
        }
        if (room.requiresCharacter) startGame(room, { mode: 'basic', preparationSeconds: 60, huntSeconds: 180 }, now());
        room.status = 'started';
        room.locked = true;
      } else if (body.status === 'waiting') {
        room.status = 'waiting';
        room.game = null;
        room.locked = false;
        room.members.forEach(m => { m.ready = room.requiresCharacter ? false : m.host; });
      } else fail(400, 'Choose a valid room action.');
      return [200, { room: snapshot(room) }];
    }
    fail(405, 'This action is not supported.');
  }

  // A disguise is checked against the room, stored, then published under a second lock,
  // so a slow 20 MB upload never holds the room.
  async function publish(req, code, token) {
    const owner = await store.withRoom(code, room => {
      const member = authenticate(enter(room), token);
      return { roomID: room.id, memberID: member.id };
    });
    if (req.headers['content-type'] !== 'model/gltf-binary') fail(415, 'Send model/gltf-binary.');
    if (uploading + UPLOAD > maxUploading) fail(503, 'The server has reached its disguise memory limit. Try again shortly.');
    uploading += UPLOAD;
    let blob;
    let published = false;
    try {
      let size = 0;
      const chunks = [];
      for await (const chunk of req) {
        size += chunk.length;
        if (size > UPLOAD) fail(413, 'Disguise exceeds 20 MB.');
        chunks.push(chunk);
      }
      const data = Buffer.concat(chunks);
      acceptDisguise({}, { id: owner.memberID }, data); // Validate the GLB before storing it.
      blob = await store.putDisguise(owner, data);
      const result = await store.withRoom(code, room => {
        const member = authenticate(enter(room), token);
        const version = acceptDisguise(room, member, data);
        const disguise = room.disguises.get(member.id);
        delete disguise.data;
        Object.assign(disguise, { blob, size: data.length });
        return { version, game: snapshotGame(room, member, now()) };
      });
      published = true;
      return result;
    } finally {
      uploading -= UPLOAD;
      if (blob !== undefined && !published) await store.discardDisguise(blob);
    }
  }

  return async function handleLobby(req, res, pathname) {
    res.setHeader('Content-Type', 'application/json; charset=utf-8');
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    const send = (status, data) => { res.writeHead(status); res.end(JSON.stringify(data)); };
    try {
      for (const [key, value] of rates) if (now() >= value.until) rates.delete(key);
      const path = pathname ?? new URL(req.url, 'http://localhost').pathname;
      if (req.method === 'GET' && path === '/health') return send(200, { status: 'ok', service: 'rally' });
      const token = req.headers.authorization?.replace(/^Bearer /, '');
      const gameCode = path.match(/^\/rooms\/(\d{6})\/game$/)?.[1];
      // Game actions are budgeted per player token; membership is checked under the room lock.
      const rateKey = gameCode && token ? `game:${gameCode}:${hashToken(token)}` : req.socket.remoteAddress;
      if (req.method !== 'GET') limit(rateKey);
      const disguiseUpload = req.method === 'POST' && /^\/rooms\/\d{6}\/disguise$/.test(path);
      const body = ['POST', 'PATCH'].includes(req.method) && !disguiseUpload ? await readBody(req, path.endsWith('/game') ? 256 * 1024 : LIMIT) : {};
      if (req.method === 'POST' && path === '/rooms') {
        profile(body);
        return send(201, await store.createRoom(room => {
          room.requiresCharacter = body.requiresCharacter === true;
          return addMember(room, body, true);
        },
          { time: now(), maxRooms, memberTTL, idleTTL, prune }));
      }
      const match = path.match(/^\/rooms\/(\d{6})(?:\/(join|me|leave|game|disguise(?:\/([a-zA-Z0-9-]+))?|members\/([a-zA-Z0-9-]+)))?$/);
      if (!match) fail(404, 'This endpoint does not exist.');
      const [, code, action, disguiseID, targetID] = match;
      if (disguiseUpload) return send(200, await publish(req, code, token));
      let status, data, blob;
      try {
        [status, data, blob] = await store.withRoom(code, room => act(room, req, body, action, disguiseID, targetID, token));
      } catch (error) {
        // Unknown tokens on game actions still count against the address.
        if (error.status === 401 && req.method !== 'GET' && rateKey !== req.socket.remoteAddress) limit(req.socket.remoteAddress);
        throw error;
      }
      if (blob === undefined) return send(status, data);
      const model = await store.readDisguise(blob);
      res.setHeader('Content-Type', 'model/gltf-binary');
      res.writeHead(200); res.end(model);
    } catch (error) {
      if (!error.status || error.cause) console.error(error.cause ?? error);
      if (error.retryAfter) res.setHeader('Retry-After', String(error.retryAfter));
      if (!res.headersSent) send(error.status ?? 500, {
        error: error.status ? error.message : 'Something went wrong. Try again.'
      });
      else res.destroy();
    }
  };
}
