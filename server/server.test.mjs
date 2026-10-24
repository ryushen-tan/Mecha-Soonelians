import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { createLobbyHandler } from './lib/lobby.mjs';

const externalBase = process.env.RALLY_TEST_URL;

async function setup(t, options = {}) {
  let base = externalBase;
  if (!base) {
    const handler = createLobbyHandler(options);
    const server = http.createServer((req, res) => handler(req, res));
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    t.after(() => new Promise(resolve => { server.close(resolve); server.closeAllConnections(); }));
    base = `http://127.0.0.1:${server.address().port}`;
  }
  const call = async (path, method = 'GET', body, token) => {
    const response = await fetch(base + path, { method,
      headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
      body: body === undefined ? undefined : JSON.stringify(body) });
    return { status: response.status, ...await response.json() };
  };
  const host = await call('/rooms', 'POST', { name: 'Kai', avatar: 0 });
  assert.equal(host.status, 201);
  const path = `/rooms/${host.room.code}`;
  return { call, host, path, base };
}

test('create, join, poll, ready, start, reset, leave and end across independent tokens', async t => {
  const { call, host, path } = await setup(t);
  assert.match(host.room.code, /^\d{6}$/);
  assert.equal(host.room.members.length, 1);
  assert.equal(host.room.members[0].host, true);
  assert.equal(host.room.members[0].ready, true);
  const guest = await call(`${path}/join`, 'POST', { name: 'Maya', avatar: 1 });
  assert.equal(guest.status, 201);
  assert.notEqual(guest.token, host.token);
  assert.equal((await call(path, 'GET', undefined, host.token)).room.members.length, 2);
  assert.equal((await call(path, 'PATCH', { status: 'started' }, host.token)).status, 409);
  assert.equal((await call(`${path}/me`, 'PATCH', { ready: true }, guest.token)).status, 200);
  const started = await call(path, 'PATCH', { status: 'started' }, host.token);
  assert.equal(started.room.status, 'started');
  assert.equal(started.room.locked, true);
  assert.equal((await call(`${path}/join`, 'POST', { name: 'Alex', avatar: 2 })).status, 409);
  assert.equal((await call(`${path}/me`, 'PATCH', { ready: false }, guest.token)).status, 409);
  const reset = await call(path, 'PATCH', { status: 'waiting' }, host.token);
  assert.equal(reset.room.locked, false);
  assert.equal(reset.room.members[1].ready, false);
  assert.equal((await call(`${path}/leave`, 'POST', {}, guest.token)).status, 200);
  assert.equal((await call(path, 'GET', undefined, guest.token)).status, 401);
  assert.equal((await call(`${path}/leave`, 'POST', {}, host.token)).status, 200);
  assert.equal((await call(path, 'GET', undefined, host.token)).status, 404);
});

test('membership authentication and host-only mutations protect rooms and tokens', async t => {
  const { call, host, path } = await setup(t);
  const guest = await call(`${path}/join`, 'POST', { name: 'Maya', avatar: 1 });
  assert.equal((await call(path)).status, 401);
  assert.equal((await call(path, 'GET', undefined, 'wrong-token')).status, 401);
  for (const body of [{ locked: true }, { status: 'started' }, { status: 'waiting' }]) {
    assert.equal((await call(path, 'PATCH', body, guest.token)).status, 403);
  }
  assert.equal((await call(`${path}/members/${host.memberID}`, 'DELETE', undefined, guest.token)).status, 403);
  const snapshot = await call(path, 'GET', undefined, guest.token);
  for (const member of snapshot.room.members) {
    assert.deepEqual(Object.keys(member).sort(), ['avatar', 'host', 'id', 'name', 'ready']);
  }
  const secondHost = await call('/rooms', 'POST', { name: 'Other', avatar: 0 });
  assert.equal((await call(path, 'GET', undefined, secondHost.token)).status, 401);
  assert.equal((await call(`${path}/members/${guest.memberID}`, 'DELETE', undefined, host.token)).status, 200);
  assert.equal((await call(path, 'GET', undefined, guest.token)).status, 401);
  assert.equal((await call(`${path}/members/${guest.memberID}`, 'DELETE', undefined, host.token)).status, 409);
  assert.equal((await call(`${path}/members/${host.memberID}`, 'DELETE', undefined, host.token)).status, 400);
});

test('unlocked rooms grow beyond the old cap while locks and duplicate names are enforced', async t => {
  const { call, host, path } = await setup(t);
  await call(path, 'PATCH', { locked: true }, host.token);
  assert.equal((await call(`${path}/join`, 'POST', { name: 'Maya', avatar: 1 })).status, 409);
  await call(path, 'PATCH', { locked: false }, host.token);
  assert.equal((await call(`${path}/join`, 'POST', { name: ' kai ', avatar: 1 })).status, 409);
  const attempts = await Promise.all(Array.from({ length: 64 }, (_, i) => call(`${path}/join`, 'POST', { name: `Guest ${i}`, avatar: i % 6 })));
  assert.ok(attempts.every(x => x.status === 201));
  const snapshot = (await call(path, 'GET', undefined, host.token)).room;
  assert.equal(snapshot.members.length, 65);
  assert.equal('capacity' in snapshot, false);
});

test('invalid input and oversized bodies are rejected without creating rooms', async t => {
  const { call, base } = await setup(t);
  for (const body of [null, [], { name: '', avatar: 0 },
    { name: 'a'.repeat(21), avatar: 0 }, { name: 'a\u200Bb', avatar: 0 },
    { name: 'Kai', avatar: 6 }]) {
    assert.equal((await call('/rooms', 'POST', body)).status, 400);
  }
  const malformed = await fetch(base + '/rooms', { method: 'POST', body: '{broken' });
  assert.equal(malformed.status, 400);
  const oversized = await fetch(base + '/rooms', { method: 'POST', body: JSON.stringify({ name: 'a'.repeat(5000) }) });
  assert.equal(oversized.status, 413);
  assert.equal((await call('/rooms/not-a-code/join', 'POST', {})).status, 404);
});

test('inactive guests expire while host heartbeat keeps the room alive', { skip: !!externalBase }, async t => {
  let time = 0;
  const { call, host, path } = await setup(t, { now: () => time, memberTTL: 1000 });
  const guest = await call(`${path}/join`, 'POST', { name: 'Maya', avatar: 1 });
  time = 600;
  await call(path, 'GET', undefined, host.token);
  time = 1100;
  assert.equal((await call(path, 'GET', undefined, host.token)).room.members.length, 1);
  assert.equal((await call(path, 'GET', undefined, guest.token)).status, 401);
  time = 2200;
  assert.equal((await call(path, 'GET', undefined, host.token)).status, 404);
});

test('mutation rate and room count limits are bounded', { skip: !!externalBase }, async t => {
  const limited = await setup(t, { rateLimit: 2 });
  await limited.call(`${limited.path}/join`, 'POST', { name: 'Maya', avatar: 1 });
  assert.equal((await limited.call(`${limited.path}/join`, 'POST', { name: 'Alex', avatar: 2 })).status, 429);
  assert.equal((await limited.call(limited.path, 'GET', undefined, limited.host.token)).status, 200);
  const full = await setup(t, { maxRooms: 1 });
  assert.equal((await full.call('/rooms', 'POST', { name: 'Other', avatar: 0 })).status, 503);
});
