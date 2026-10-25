import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { startAR, beginRound, skipPhase, placeGhost, reportSeen, tagGhost, snapshotAR, clearAR } from './lib/ar.mjs';

const options = { house: { kind: 'bundled', id: '12345678' }, hideSeconds: 60, seekSeconds: 60 };
const roomFixture = () => ({ members: ['Kai', 'Bok', 'Ryu'].map((name, index) =>
  ({ id: randomUUID(), name, avatar: index, host: index === 0, ready: true })) });
function hide(room, owner, time) {
  const identity = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];
  const ghost = { id: randomUUID(), ownerID: owner.id, transform: identity, floorTransform: identity,
    flushBack: false, hasModel: false, width: 0.5, height: 1.75 };
  placeGhost(room, owner, ghost, time);
  return ghost;
}
const scores = state => state.players.map(({ points, totalPoints }) => [points, totalPoints]);

test('AR leaderboard carries totals across rounds and role changes without counting polls twice', () => {
  const room = roomFixture(), [host, bok, ryu] = room.members;
  startAR(room, options, 0, () => 0);
  beginRound(room, host, 0);
  const first = hide(room, bok, 0), second = hide(room, ryu, 0);
  skipPhase(room, host, 0);
  reportSeen(room, host, [first.id, second.id], 0);
  reportSeen(room, host, [first.id, second.id], 1000);
  reportSeen(room, host, [first.id], 2000);
  skipPhase(room, host, 2000);
  for (const member of room.members) {
    const snapshot = snapshotAR(room, member, 2500);
    assert.equal(snapshot.roundNumber, 1);
    assert.deepEqual(scores(snapshot), [[0, 0], [20, 20], [10, 10]]);
    assert.deepEqual(snapshot.winnerIDs, [bok.id]);
  }
  // Simulate the persisted JSON being read by a different server instance.
  room.ar = JSON.parse(JSON.stringify(room.ar));
  startAR(room, options, 3000, () => 1);
  assert.equal(room.ar.roundNumber, 2);
  assert.deepEqual(scores(snapshotAR(room, host, 3000)), [[0, 0], [0, 20], [0, 10]]);
  assert.throws(() => startAR(room, options, 3001), { status: 409 });
  beginRound(room, host, 3000);
  const third = hide(room, host, 3000), fourth = hide(room, ryu, 3000);
  skipPhase(room, host, 3000);
  reportSeen(room, bok, [third.id, fourth.id], 3000);
  reportSeen(room, bok, [third.id, fourth.id], 4000);
  tagGhost(room, bok, third.id, 4000);
  tagGhost(room, bok, fourth.id, 4000);
  tagGhost(room, bok, fourth.id, 4001);
  const end = snapshotAR(room, host, 4500);
  assert.equal(end.phase, 'results');
  assert.deepEqual(end.winnerIDs, [bok.id]);
  assert.deepEqual(scores(end), [[10, 10], [0, 20], [10, 20]]);
  startAR(room, options, 5000, () => 2);
  assert.deepEqual(scores(snapshotAR(room, ryu, 5000)), [[0, 10], [0, 20], [0, 20]]);
  clearAR(room);
  startAR(room, options, 6000, () => 0);
  assert.equal(room.ar.roundNumber, 1);
  assert.deepEqual(scores(snapshotAR(room, host, 6000)), [[0, 0], [0, 0], [0, 0]]);
});

test('legacy results carry forward and newcomers never inherit a departed player score', () => {
  const room = roomFixture(), [host, bok, ryu] = room.members;
  startAR(room, options, 0, () => 0);
  room.ar.phase = 'results';
  room.ar.exposure = { [bok.id]: 2400, [ryu.id]: 4100 };
  delete room.ar.scoreTotals;
  delete room.ar.roundNumber;
  assert.deepEqual(scores(snapshotAR(room, host, 1)), [[0, 0], [20, 20], [40, 40]]);
  const newcomer = { ...ryu, id: randomUUID() };
  room.members = [host, bok, newcomer];
  startAR(room, options, 2, () => 0);
  assert.equal(room.ar.roundNumber, 2);
  assert.deepEqual(scores(snapshotAR(room, newcomer, 2)), [[0, 0], [0, 20], [0, 0]]);
});

test('timer-ended rounds and zero-point rounds preserve totals without changing winner rules', () => {
  const room = roomFixture(), [host, bok] = room.members;
  startAR(room, options, 0, () => 0);
  beginRound(room, host, 0);
  const ghost = hide(room, bok, 0);
  skipPhase(room, host, 0);
  reportSeen(room, host, [ghost.id], 0);
  reportSeen(room, host, [ghost.id], 1000);
  assert.equal(snapshotAR(room, host, 60000).phase, 'results');
  startAR(room, options, 61000, () => 0);
  beginRound(room, host, 61000);
  skipPhase(room, host, 61000);
  skipPhase(room, host, 62000);
  const end = snapshotAR(room, host, 62000);
  assert.deepEqual(end.winnerIDs, []);
  assert.deepEqual(scores(end), [[0, 0], [0, 10], [0, 0]]);
});
