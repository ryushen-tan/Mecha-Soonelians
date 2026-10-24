import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { readFileSync } from 'node:fs';
import { createLobbyHandler } from './lib/lobby.mjs';
import { startGame, snapshotGame, shoot, taunt, acceptDisguise, rayBox, recordView, emergencyEject } from './lib/game.mjs';

const box = (horizontal = 0) => ({ id: '0', min: [horizontal - 0.3, 0, -0.3], max: [horizontal + 0.3, 1.8, 0.3] });
function disguise(boxes = [box()]) {
  const data = readFileSync(new URL('../TestFixtures/Character3D/test-rig.glb', import.meta.url));
  const length = data.readUInt32LE(12);
  const json = JSON.parse(data.subarray(20, 20 + length));
  json.nodes[0].extras = { disguises: boxes };
  const text = Buffer.from(JSON.stringify(json));
  const padded = Buffer.alloc(Math.ceil(text.length / 4) * 4, 32);
  text.copy(padded);
  const header = Buffer.alloc(20);
  header.write('glTF'); header.writeUInt32LE(2, 4); header.writeUInt32LE(20 + padded.length + data.length - 20 - length, 8);
  header.writeUInt32LE(padded.length, 12); header.writeUInt32LE(0x4e4f534a, 16);
  return Buffer.concat([header, padded, data.subarray(20 + length)]);
}

function room() {
  const members = ['hunter', 'first', 'second'].map((id, index) => ({ id, name: id, host: index === 0, ready: true }));
  const room = { members, status: 'waiting' };
  members.forEach((member, index) => acceptDisguise(room, member, disguise([box(index === 0 ? -4 : index === 1 ? 0 : 8), box(index === 0 ? -3 : index === 1 ? 2 : 9)])));
  return room;
}

const config = mode => ({ mode, preparationSeconds: 0, huntSeconds: 60, autoTauntSeconds: 0, room: { surfaces: [] } });
const ray = horizontal => ({ origin: [horizontal, 1, -2], direction: [0, 0, 1], targetID: horizontal < -2 ? 'hunter' : horizontal > 5 ? 'second' : 'first' });
const ejectFloor = { id: 'floor', kind: 'floor', dimensions: [12, 0.1, 12], position: [0, -0.05, 0] };

test('emergency eject moves the published body and clones once, preserving appearance and scoring', () => {
  const gameRoom = room();
  startGame(gameRoom, { ...config('basic'), room: { surfaces: [ejectFloor] } }, 1000);
  const member = gameRoom.members[1], original = gameRoom.disguises.get(member.id);
  assert.equal(snapshotGame(gameRoom, member, 1000).eject.available, true);
  emergencyEject(gameRoom, member, 1000, () => 0.65);
  const moved = gameRoom.disguises.get(member.id);
  assert.equal(moved.data, original.data);
  assert.notEqual(moved.version, original.version);
  assert.ok(Math.hypot(moved.offset[0], moved.offset[2]) >= 0.75);
  for (const [index, bounds] of moved.boxes.entries()) {
    bounds.min.forEach((value, axis) => assert.ok(Math.abs(value - original.boxes[index].min[axis] - moved.offset[axis]) < 0.00001));
    bounds.max.forEach((value, axis) => assert.ok(Math.abs(value - original.boxes[index].max[axis] - moved.offset[axis]) < 0.00001));
  }
  assert.equal(snapshotGame(gameRoom, member, 1000).eject.used, true);
  assert.equal(snapshotGame(gameRoom, member, 1000).eject.available, false);
  assert.throws(() => emergencyEject(gameRoom, member, 1000), /already used/);
  assert.equal(shoot(gameRoom, gameRoom.members[0], ray(0), 1000).hit, false);
  const clone = moved.boxes[1];
  const origin = clone.min.map((value, axis) => (value + clone.max[axis]) / 2); origin[2] -= 2;
  assert.equal(shoot(gameRoom, gameRoom.members[0], { origin, direction: [0, 0, 1], targetID: member.id }, 2000).hit, true);
  assert.equal(gameRoom.game.scores.hunter, 500);
  assert.throws(() => acceptDisguise(gameRoom, member, disguise()), /stay locked/);
});

test('eject rejects preparation, hunters, found players and finished rounds; each round resets its use', () => {
  const gameRoom = room(), member = gameRoom.members[1];
  const options = { ...config('basic'), preparationSeconds: 2, room: { surfaces: [ejectFloor] } };
  startGame(gameRoom, options, 1000);
  assert.throws(() => emergencyEject(gameRoom, member, 1000), /active hiding/);
  assert.throws(() => emergencyEject(gameRoom, gameRoom.members[0], 3000), /active hiding/);
  emergencyEject(gameRoom, member, 3000, () => 0.65);
  gameRoom.game.found.second = true;
  assert.throws(() => emergencyEject(gameRoom, gameRoom.members[2], 3000), /active hiding/);
  assert.throws(() => emergencyEject(gameRoom, member, 100000), /active hiding/);
  startGame(gameRoom, { ...options, preparationSeconds: 0 }, 101000);
  assert.equal(snapshotGame(gameRoom, member, 101000).eject.available, true);
  emergencyEject(gameRoom, member, 101000, () => 0.35);
});

test('eject rejects blocked or undersized spots without consuming the one use', () => {
  const gameRoom = room(), member = gameRoom.members[1];
  startGame(gameRoom, { ...config('basic'), room: { surfaces: [ejectFloor, { kind: 'object', dimensions: [1, 2, 1], position: [1.8, 1, 1.8] }] } }, 1000);
  const original = gameRoom.disguises.get(member.id);
  assert.throws(() => emergencyEject(gameRoom, member, 1000, () => 0.65), /No different spot/);
  assert.equal(gameRoom.disguises.get(member.id), original);
  assert.equal(snapshotGame(gameRoom, member, 1000).eject.available, true);
  emergencyEject(gameRoom, member, 1000, () => 0.35);
  const tiny = room();
  startGame(tiny, { ...config('basic'), room: { surfaces: [{ ...ejectFloor, dimensions: [0.2, 0.1, 0.2] }] } }, 1000);
  assert.throws(() => emergencyEject(tiny, tiny.members[1], 1000), /No different spot/);
  assert.equal(snapshotGame(tiny, tiny.members[1], 1000).eject.used, false);
});

test('eject supports RoomPlan floors with a transformed local normal', () => {
  const gameRoom = room(), member = gameRoom.members[1];
  const floor = { kind: 'floor', dimensions: [12, 12, 0.1], transform: [1, 0, 0, 0, 0, 0, -1, 0, 0, 1, 0, 0, 10, 2, 10, 1] };
  startGame(gameRoom, { ...config('basic'), room: { surfaces: [floor] } }, 1000);
  emergencyEject(gameRoom, member, 1000, () => 0.65);
  const moved = gameRoom.disguises.get(member.id);
  assert.ok(Math.abs(moved.boxes[0].min[1] - 2.056) < 0.00001);
  assert.ok(moved.boxes.every(bounds => bounds.min[0] > 4 && bounds.max[0] < 16 && bounds.min[2] > 4 && bounds.max[2] < 16));
});

test('visible hiding earns exposure points, but walls and stale views do not', () => {
  const gameRoom = room(); startGame(gameRoom, config('basic'), 1000);
  recordView(gameRoom, gameRoom.members[0], { ...ray(0), fov: 38, aspect: 1 }, 1000);
  assert.equal(snapshotGame(gameRoom, gameRoom.members[0], 2000).scores.find(score => score.id === 'first').points, 10);
  gameRoom.game.surfaces = [{ kind: 'wall', position: [0, 1, -1], dimensions: [8, 3, 0.1] }];
  snapshotGame(gameRoom, gameRoom.members[0], 3000);
  assert.equal(gameRoom.game.scores.first, 10);
  gameRoom.game.surfaces = [];
  snapshotGame(gameRoom, gameRoom.members[0], 9000);
  assert.equal(gameRoom.game.scores.first, 10);
});

test('basic mode protects the prep phase and a clone hit finds its owner once', () => {
  const gameRoom = room();
  startGame(gameRoom, { ...config('basic'), preparationSeconds: 2 }, 1000);
  const hunter = gameRoom.members[0], first = gameRoom.members[1];
  assert.deepEqual(snapshotGame(gameRoom, hunter, 1000).visible.map(item => item.id), ['hunter']);
  assert.equal(snapshotGame(gameRoom, first, 1000).visible.length, 2);
  assert.throws(() => shoot(gameRoom, hunter, ray(2), 1000), /Hunters/);
  assert.equal(shoot(gameRoom, hunter, ray(2), 3000).targetID, 'first');
  assert.equal(gameRoom.game.found.first, true);
  assert.equal(gameRoom.game.scores.hunter, 500);
  assert.equal(shoot(gameRoom, hunter, ray(0), 4000).hit, false);
  assert.equal(gameRoom.game.scores.hunter, 500);
  assert.equal(snapshotGame(gameRoom, hunter, 64000).winner, 'hiders');
  assert.doesNotThrow(() => acceptDisguise(gameRoom, first, disguise()), 'Found players can publish a new disguise after the round finishes.');
});

test('infection converts a found hider into a hunter and hides teammate geometry', () => {
  const gameRoom = room(); startGame(gameRoom, config('infection'), 1000);
  assert.deepEqual(snapshotGame(gameRoom, gameRoom.members[1], 1000).visible.map(item => item.id), ['first']);
  shoot(gameRoom, gameRoom.members[0], ray(0), 1000);
  assert.equal(snapshotGame(gameRoom, gameRoom.members[1], 1000).role, 'hunter');
  assert.equal(shoot(gameRoom, gameRoom.members[1], ray(8), 2000).targetID, 'second');
  assert.equal(snapshotGame(gameRoom, gameRoom.members[1], 2000).winner, 'hunters');
});

test('double mode gives each hunter points without double-counting a target', () => {
  const gameRoom = room(); startGame(gameRoom, config('double'), 1000);
  assert.equal(shoot(gameRoom, gameRoom.members[0], ray(0), 1000).hit, true);
  assert.equal(shoot(gameRoom, gameRoom.members[0], ray(0), 2000).hit, false);
  assert.equal(gameRoom.game.scores.hunter, 500);
  assert.equal(gameRoom.game.found.first, undefined);
  assert.equal(shoot(gameRoom, gameRoom.members[2], ray(0), 3000).hit, true);
});

test('chicken race reveals one target at a time and awards 500 points per find', () => {
  const gameRoom = room(); startGame(gameRoom, config('chicken'), 1000);
  assert.equal(snapshotGame(gameRoom, gameRoom.members[1], 1000).targetID, 'hunter');
  assert.equal(shoot(gameRoom, gameRoom.members[1], ray(0), 1000).hit, false);
  assert.equal(shoot(gameRoom, gameRoom.members[1], ray(-3), 2000).hit, true);
  assert.equal(gameRoom.game.scores.first, 500);
  assert.equal(snapshotGame(gameRoom, gameRoom.members[1], 22000).targetID, 'first');
});

test('wall occlusion blocks tags while actual door openings allow them', () => {
  const wall = { kind: 'wall', position: [0, 1, -1], dimensions: [4, 3, 0.1] };
  const blocked = room(); startGame(blocked, { ...config('basic'), room: { surfaces: [wall] } }, 1000);
  assert.equal(shoot(blocked, blocked.members[0], ray(0), 1000).hit, false);
  const doorway = room(); startGame(doorway, { ...config('basic'), room: { surfaces: [{ ...wall, holes: [[0, 0, 1, 2]] }] } }, 1000);
  assert.equal(shoot(doorway, doorway.members[0], ray(0), 1000).hit, true);
  const upstairs = room();
  startGame(upstairs, { ...config('basic'), room: { surfaces: [{ kind: 'floor', position: [0, 2, 0], dimensions: [6, 0.1, 6] }] } }, 1000);
  assert.equal(shoot(upstairs, upstairs.members[0], { origin: [0, 3, 0], direction: [0, -1, 0], targetID: 'first' }, 1000).hit, false);
  assert.equal(rayBox([0, 1, -2], [0, 0, 1], box()), 1.7);
});

test('round validation, shot cooldowns and taunts are enforced by the server', () => {
  const gameRoom = room();
  assert.throws(() => startGame(gameRoom, config('unknown'), 1000));
  startGame(gameRoom, config('basic'), 1000);
  assert.throws(() => shoot(gameRoom, gameRoom.members[1], ray(0), 1000));
  assert.throws(() => shoot(gameRoom, gameRoom.members[0], { origin: [NaN, 0, 0], direction: [0, 0, 1] }, 1000));
  taunt(gameRoom, gameRoom.members[1], 1000);
  assert.equal(snapshotGame(gameRoom, gameRoom.members[0], 1000).taunts.length, 1);
  assert.throws(() => taunt(gameRoom, gameRoom.members[1], 1100));
  shoot(gameRoom, gameRoom.members[0], ray(20), 1000);
  assert.throws(() => shoot(gameRoom, gameRoom.members[0], ray(0), 1100));
});

test('HTTP game flow publishes private GLBs, starts a match and scores a tag', async t => {
  let server;
  let base = process.env.RALLY_TEST_URL;
  if (!base) {
    const handler = createLobbyHandler();
    server = http.createServer(handler);
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    base = `http://127.0.0.1:${server.address().port}`;
    t.after(() => new Promise(resolve => { server.close(resolve); server.closeAllConnections(); }));
  }
  const call = async (path, method = 'GET', body, token, binary = false) => {
    const response = await fetch(base + path, { method, headers: { 'Content-Type': binary ? 'model/gltf-binary' : 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
      body: body == null ? undefined : binary ? body : JSON.stringify(body) });
    const data = response.headers.get('content-type')?.includes('json') ? await response.json() : Buffer.from(await response.arrayBuffer());
    return { status: response.status, data };
  };
  const host = (await call('/rooms', 'POST', { name: 'Game host', avatar: 0 })).data;
  const path = '/rooms/' + host.room.code;
  const guest = (await call(path + '/join', 'POST', { name: 'Game guest', avatar: 1 })).data;
  const data = disguise();
  assert.equal((await call(path + '/disguise', 'POST', data, undefined, true)).status, 401);
  assert.equal((await call(path + '/disguise', 'POST', data, guest.token, true)).status, 200);
  await call(path + '/me', 'PATCH', { ready: true }, guest.token);
  assert.equal((await call(path + '/game', 'POST', { action: 'start', ...config('basic'), preparationSeconds: 10 }, guest.token)).status, 403);
  assert.equal((await call(path + '/game', 'POST', { action: 'start', ...config('basic'), preparationSeconds: 10 }, host.token)).status, 200);
  assert.equal((await call(path + '/disguise/' + guest.memberID, 'GET', undefined, host.token)).status, 403);
  assert.equal((await call(path + '/disguise/' + guest.memberID, 'GET', undefined, guest.token)).status, 200);
  await call(path, 'PATCH', { status: 'waiting' }, host.token);
  await call(path + '/me', 'PATCH', { ready: true }, guest.token);
  await call(path + '/game', 'POST', { action: 'start', ...config('basic'), room: { surfaces: [ejectFloor] } }, host.token);
  assert.equal((await call(path + '/game', 'POST', { action: 'eject' })).status, 401);
  assert.equal((await call(path + '/game', 'POST', { action: 'eject' }, host.token)).status, 409);
  const ejected = await call(path + '/game', 'POST', { action: 'eject', position: [99, 99, 99] }, guest.token);
  assert.equal(ejected.status, 200);
  assert.equal(ejected.data.game.eject.used, true);
  assert.equal((await call(path + '/game', 'POST', { action: 'eject' }, guest.token)).status, 409);
  assert.equal((await call(path + '/disguise', 'POST', data, guest.token, true)).status, 409);
  const bounds = ejected.data.game.eject.bounds;
  const origin = bounds.min.map((value, axis) => (value + bounds.max[axis]) / 2); origin[2] -= 2;
  const shot = await call(path + '/game', 'POST', { action: 'shoot', origin, direction: [0, 0, 1], targetID: guest.memberID }, host.token);
  assert.equal(shot.status, 200);
  assert.equal(shot.data.result.hit, true);
  assert.equal(shot.data.game.winner, 'hunters');
  await call(path + '/leave', 'POST', {}, host.token);
});
