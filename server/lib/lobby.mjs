import { randomBytes, randomInt, randomUUID } from 'node:crypto';

const LIMIT = 4096;
const fail = (status, message) => { throw Object.assign(new Error(message), { status }); };

// One process owns the rooms. Mutations run synchronously after body parsing.
export function createLobbyHandler({ now = Date.now, idleTTL = 2 * 60 * 60 * 1000,
  memberTTL = 90_000, maxRooms = 1000, rateLimit = 180 } = {}) {
  const rooms = new Map();
  const rates = new Map();

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

  function snapshot(room) {
    return {
      code: room.code, locked: room.locked,
      status: room.status, createdAt: room.createdAt,
      members: room.members.map(({ id, name, avatar, host, ready }) => ({ id, name, avatar, host, ready }))
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

  async function readBody(req) {
    let size = 0;
    const chunks = [];
    for await (const chunk of req) {
      size += chunk.length;
      if (size > LIMIT) fail(413, 'Request is too large.');
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
      // Polls authenticate below. Bound all mutations per source, without trusting forwarded IPs.
      if (req.method !== 'GET') {
        const key = req.socket.remoteAddress;
        const rate = rates.get(key) ?? { count: 0, until: now() + 60_000 };
        rates.set(key, rate);
        if (++rate.count > rateLimit) fail(429, 'Too many attempts. Wait a minute and try again.');
      }
      const body = ['POST', 'PATCH'].includes(req.method) ? await readBody(req) : {};
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
      const match = path.match(/^\/rooms\/(\d{6})(?:\/(join|me|leave|members\/([a-zA-Z0-9-]+)))?$/);
      if (!match) fail(404, 'This endpoint does not exist.');
      const [, code, action, targetID] = match;
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
      if (req.method === 'GET' && !action) return send(200, { room: snapshot(room) });
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
