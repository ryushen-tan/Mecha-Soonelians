import { randomBytes, randomInt, randomUUID } from 'node:crypto';
import { acceptDisguise, snapshotGame, visibleOwners, startGame, shoot, taunt, recordView } from './game.mjs';

const LIMIT = 4096;
const fail = (status, message) => { throw Object.assign(new Error(message), { status }); };

// One process owns the rooms. Mutations run synchronously after body parsing.
export function createLobbyHandler({ now = Date.now, idleTTL = 2 * 60 * 60 * 1000,
  memberTTL = 90_000, maxRooms = 1000, rateLimit = 180 } = {}) {
  const rooms = new Map();
  const rates = new Map();
  let uploading = 0;

  function prune() {
    const time = now();
    for (const [code, room] of rooms) {
      if (time - room.touchedAt > idleTTL || time - room.members[0].seenAt > memberTTL) {
        rooms.delete(code);
      } else {
        room.members = room.members.filter(m => m.host || time - m.seenAt <= memberTTL);
      }
    }
    for (const [key, value] of rates) if (time >= value.until) rates.delete(key);
  }

  function snapshot(room, member) {
    return {
      code: room.code, locked: room.locked,
      status: room.status, createdAt: room.createdAt,
      members: room.members.map(({ id, name, avatar, host, ready }) => ({ id, name, avatar, host, ready })),
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
    if (room.members.some(m => m.name.toLocaleLowerCase('en-US') === details.name.toLocaleLowerCase('en-US'))) {
      fail(409, 'That name is taken in this room. Try another.');
    }
    const member = { ...details, id: randomUUID(), token: randomBytes(32).toString('hex'),
      host, ready: host, seenAt: now() };
    room.members.push(member);
    room.touchedAt = now();
    return { room: snapshot(room), memberID: member.id, token: member.token };
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

  return async function handleLobby(req, res, pathname) {
    res.setHeader('Content-Type', 'application/json; charset=utf-8');
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    const send = (status, data) => { res.writeHead(status); res.end(JSON.stringify(data)); };
    try {
      prune();
      const path = pathname ?? new URL(req.url, 'http://localhost').pathname;
      if (req.method === 'GET' && path === '/health') return send(200, { status: 'ok', service: 'rally' });
      if (req.method !== 'GET') {
        const gameCode = path.match(/^\/rooms\/(\d{6})\/game$/)?.[1];
        const suppliedToken = req.headers.authorization?.replace(/^Bearer /, '');
        const gameMember = gameCode && rooms.get(gameCode)?.members.find(member => member.token === suppliedToken);
        const key = gameMember ? `game:${gameCode}:${gameMember.id}` : req.socket.remoteAddress;
        const rate = rates.get(key) ?? { count: 0, until: now() + 60_000 };
        rates.set(key, rate);
        if (++rate.count > rateLimit) fail(429, 'Too many attempts. Wait a minute and try again.');
      }
      const disguiseUpload = req.method === 'POST' && /^\/rooms\/\d{6}\/disguise$/.test(path);
      const body = ['POST', 'PATCH'].includes(req.method) && !disguiseUpload ? await readBody(req, path.endsWith('/game') ? 256 * 1024 : LIMIT) : {};
      if (req.method === 'POST' && path === '/rooms') {
        profile(body);
        if (rooms.size >= maxRooms) fail(503, 'The server is full. Try again later.');
        let code;
        do { code = String(randomInt(100000, 1000000)); } while (rooms.has(code));
        const room = { code, locked: false, status: 'waiting',
          createdAt: new Date(now()).toISOString(), touchedAt: now(), members: [] };
        const result = addMember(room, body, true);
        rooms.set(code, room);
        return send(201, result);
      }
      const match = path.match(/^\/rooms\/(\d{6})(?:\/(join|me|leave|game|disguise(?:\/([a-zA-Z0-9-]+))?|members\/([a-zA-Z0-9-]+)))?$/);
      if (!match) fail(404, 'This endpoint does not exist.');
      const [, code, action, disguiseID, targetID] = match;
      const room = rooms.get(code);
      if (!room) fail(404, 'Room not found. Check the code or ask the host for a new one.');
      if (req.method === 'POST' && action === 'join') {
        if (room.status !== 'waiting') fail(409, 'This session has already started.');
        if (room.locked) fail(409, 'This room is locked. Ask the host to unlock it.');
        return send(201, addMember(room, body, false));
      }
      const token = req.headers.authorization?.replace(/^Bearer /, '');
      const member = room.members.find(m => m.token === token);
      if (!member) fail(401, 'You are no longer in this room. Join again with the room code.');
      member.seenAt = now();
      room.touchedAt = now();
      if (req.method === 'GET' && !action) return send(200, { room: snapshot(room, member) });
      if (action === 'game') {
        if (req.method === 'GET') return send(200, { game: snapshotGame(room, member, now()) });
        if (req.method !== 'POST') fail(405, 'Unsupported game action.');
        let result;
        if (body.action === 'start') {
          if (!member.host) fail(403, 'Only the host can start a round.');
          if (room.game && room.game.phase !== 'finished') fail(409, 'A round is already running.');
          startGame(room, body, now());
        } else if (body.action === 'shoot') result = shoot(room, member, body, now());
        else if (body.action === 'taunt') taunt(room, member, now());
        else if (body.action === 'view') recordView(room, member, body, now());
        else fail(400, 'Choose a supported game action.');
        return send(200, { game: snapshotGame(room, member, now()), result: result ?? null });
      }
      if (action?.startsWith('disguise')) {
        if (req.method === 'GET' && disguiseID) {
          if (!visibleOwners(room, member, now()).includes(disguiseID)) fail(403, 'That disguise is hidden in this phase or game mode.');
          const disguise = room.disguises?.get(disguiseID);
          if (!disguise) fail(404, 'Disguise not published.');
          res.setHeader('Content-Type', 'model/gltf-binary');
          res.writeHead(200); res.end(disguise.data); return;
        }
        if (!disguiseUpload || disguiseID) fail(405, 'Unsupported disguise action.');
        if (req.headers['content-type'] !== 'model/gltf-binary') fail(415, 'Send model/gltf-binary.');
        const existingBytes = [...rooms.values()].reduce((total, room) => total + [...(room.disguises?.values() ?? [])].reduce((size, item) => size + item.data.length, 0), 0);
        const reservation = 20 * 1024 * 1024;
        if (existingBytes + uploading + reservation > 256 * 1024 * 1024) fail(503, 'The development server has reached its disguise memory limit.');
        uploading += reservation;
        try {
          let size = 0;
          const chunks = [];
          for await (const chunk of req) {
            size += chunk.length;
            if (size > reservation) fail(413, 'Disguise exceeds 20 MB.');
            chunks.push(chunk);
          }
          const version = acceptDisguise(room, member, Buffer.concat(chunks));
          return send(200, { version, game: snapshotGame(room, member, now()) });
        } finally { uploading -= reservation; }
      }
      if (req.method === 'POST' && action === 'leave') {
        if (member.host) rooms.delete(code);
        else room.members = room.members.filter(m => m.id !== member.id);
        return send(200, { ok: true });
      }
      if (req.method === 'PATCH' && action === 'me') {
        if (typeof body.ready !== 'boolean') fail(400, 'Ready must be true or false.');
        if (room.status !== 'waiting') fail(409, 'The session has already started.');
        if (!member.host) member.ready = body.ready;
        return send(200, { room: snapshot(room) });
      }
      if (!member.host) fail(403, 'Only the host can change the room.');
      if (req.method === 'DELETE' && targetID) {
        if (targetID === member.id) fail(400, 'Use End room to leave as the host.');
        if (!room.members.some(m => m.id === targetID)) fail(409, 'That player has already left.');
        room.members = room.members.filter(m => m.id !== targetID);
        return send(200, { room: snapshot(room) });
      }
      if (req.method === 'PATCH' && !action) {
        if ('locked' in body) {
          if (typeof body.locked !== 'boolean') fail(400, 'Locked must be true or false.');
          room.locked = body.locked;
        } else if (body.status === 'started') {
          if (room.status !== 'waiting') fail(409, 'This session has already started.');
          if (room.members.length < 2 || !room.members.every(m => m.ready)) {
            fail(409, 'At least two players must be in the room and everyone must be ready.');
          }
          room.status = 'started';
          room.locked = true;
        } else if (body.status === 'waiting') {
          room.status = 'waiting';
          room.game = null;
          room.locked = false;
          room.members.forEach(m => { m.ready = m.host; });
        } else fail(400, 'Choose a valid room action.');
        return send(200, { room: snapshot(room) });
      }
      fail(405, 'This action is not supported.');
    } catch (error) {
      if (!res.headersSent) send(error.status ?? 500, {
        error: error.status ? error.message : 'Something went wrong. Try again.'
      });
    }
  };
}
