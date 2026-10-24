import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { readFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { createCharactersHandler, Conflict } from './lib/characters.mjs';

const png = readFileSync(new URL('../TestFixtures/HumanDepth/human-1-cutout.png', import.meta.url));
const glb = Buffer.alloc(12);
glb.write('glTF');
glb.writeUInt32LE(2, 4);
glb.writeUInt32LE(12, 8);

function memoryStore() {
  const jobs = new Map();
  const models = new Map();
  const counted = [];
  let version = 0;
  const copy = value => JSON.parse(JSON.stringify(value));
  return {
    jobs, models,
    async read(id) { const entry = jobs.get(id); return entry && { job: copy(entry.job), etag: entry.etag }; },
    async create(id, job) {
      if (jobs.has(id)) throw new Conflict();
      jobs.set(id, { job: copy(job), etag: String(++version) });
      return String(version);
    },
    async update(id, job, etag) {
      if (jobs.get(id)?.etag !== etag) throw new Conflict();
      jobs.set(id, { job: copy(job), etag: String(++version) });
      return String(version);
    },
    async saveModel(id, kind, data) { models.set(`${id}/${kind}`, data); },
    async modelURL(id, kind) { return `https://blob.test/${id}/${kind}.glb`; },
    async count(id, createdAt) { counted.push(createdAt); },
    async countSince(time) { return counted.filter(at => at >= time).length; }
  };
}

async function setup(t, { riggable = true, status = 'success', ...options } = {}) {
  const calls = [];
  const api = {
    upload: async () => 'file_test',
    create: async (path, body) => { calls.push({ path, body }); return { task_id: 'task_' + calls.length }; },
    task: async id => ({ status, progress: status === 'success' ? 100 : 40, credits_consumed: 1,
      output: id === 'task_2' ? { riggable, rig_type: 'biped' } : { model_url: 'https://cdn.tripo3d.ai/test.glb' } }),
    download: async () => glb
  };
  const store = memoryStore();
  const handle = createCharactersHandler({ api, store, apiKey: 'test-key', accessToken: 'proxy', ...options });
  const server = http.createServer((req, res) => handle(req, res, new URL(req.url, 'http://localhost').pathname));
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => { server.close(resolve); server.closeAllConnections(); }));
  const base = `http://127.0.0.1:${server.address().port}`;
  const auth = { Authorization: 'Bearer proxy' };
  const send = (id, headers = {}, data = png) => fetch(base + '/characters', {
    method: 'POST', headers: { 'Content-Type': 'image/png', 'X-Request-ID': id, ...auth, ...headers }, body: data
  });
  const poll = id => fetch(base + '/characters/' + id, { headers: auth });
  const wait = async id => {
    for (let attempt = 0; attempt < 20; attempt++) {
      const job = await (await poll(id)).json();
      if (job.status !== 'working') return job;
    }
    throw new Error('Job did not finish');
  };
  return { send, poll, wait, base, auth, calls, store, api };
}

test('each poll advances one stage; replaying the request does not spend credits twice', async t => {
  const { send, wait, base, auth, calls, store } = await setup(t);
  const id = randomUUID();
  const created = await send(id);
  assert.equal(created.status, 202);
  assert.equal((await created.json()).stage, 'generating');
  const job = await wait(id);
  assert.equal(job.status, 'ready');
  assert.equal(job.rigged, true);
  assert.equal(job.credits, 3);
  assert.equal((await send(id)).status, 200);
  assert.deepEqual(calls.map(call => call.path), ['generation/image-to-model', 'animations/rig-check', 'animations/rig']);
  assert.equal(calls[0].body.input, 'file_test');
  assert.equal(calls[2].body.spec, 'mixamo');
  assert.equal(JSON.stringify(store.jobs.get(id).job).includes('file_test'), false);
  assert.ok(store.models.has(`${id}/mesh`) && store.models.has(`${id}/rigged`));
  const model = await fetch(`${base}/characters/${id}/model`, { headers: auth, redirect: 'manual' });
  assert.equal(model.status, 302);
  assert.equal(model.headers.get('location'), `https://blob.test/${id}/rigged.glb`);
  const changed = Buffer.from(png);
  changed[changed.length - 1] ^= 1;
  assert.equal((await send(id, {}, changed)).status, 409);
});

test('concurrent polls submit each paid stage only once', async t => {
  const { send, poll, wait, calls } = await setup(t);
  const id = randomUUID();
  await send(id);
  await Promise.all(Array.from({ length: 6 }, () => poll(id)));
  await Promise.all(Array.from({ length: 6 }, () => poll(id)));
  assert.equal((await wait(id)).status, 'ready');
  assert.deepEqual(calls.map(call => call.path), ['generation/image-to-model', 'animations/rig-check', 'animations/rig']);
});

test('keeps the mesh when rig-check fails, and X-Rig: 0 skips rigging', async t => {
  const { send, wait, base, auth, calls } = await setup(t, { riggable: false });
  const id = randomUUID();
  await send(id);
  const job = await wait(id);
  assert.equal(job.status, 'ready');
  assert.equal(job.rigged, false);
  assert.match(job.warning, /standing/);
  assert.equal(calls.length, 2);
  const model = await fetch(`${base}/characters/${id}/model`, { headers: auth, redirect: 'manual' });
  assert.equal(model.headers.get('location'), `https://blob.test/${id}/mesh.glb`);

  const ghost = randomUUID();
  await send(ghost, { 'X-Rig': '0' });
  assert.equal((await wait(ghost)).status, 'ready');
  assert.equal(calls.length, 3);
});

test('a rigging failure still leaves the mesh ready', async t => {
  const { send, poll, api } = await setup(t);
  const id = randomUUID();
  await send(id);
  await poll(id); // generation done, rig-check submitted
  await poll(id); // rig-check done, rigging submitted
  api.task = async () => ({ status: 'failed' });
  const job = await (await poll(id)).json();
  assert.equal(job.status, 'ready');
  assert.equal(job.rigged, false);
  assert.match(job.warning, /rigging did not complete/);
});

test('reports progress while Tripo works and fails cleanly when generation fails', async t => {
  const { send, poll, api } = await setup(t, { status: 'running' });
  const id = randomUUID();
  await send(id);
  const working = await (await poll(id)).json();
  assert.equal(working.status, 'working');
  assert.equal(working.progress, 40);
  api.task = async () => ({ status: 'banned' });
  const job = await (await poll(id)).json();
  assert.equal(job.status, 'failed');
  assert.match(job.error, /generating banned/);
});

test('requires the access token, rejects browsers and enforces the daily limit', async t => {
  const { send, base } = await setup(t, { maxJobsPerDay: 1 });
  assert.equal((await send(randomUUID(), { Authorization: 'Bearer test-key' })).status, 401);
  assert.equal((await send(randomUUID(), { Origin: 'https://example.com' })).status, 403);
  assert.equal((await fetch(base + '/characters/' + randomUUID(), { headers: { Authorization: 'Bearer proxy' } })).status, 404);
  assert.equal((await send(randomUUID())).status, 202);
  const limited = await send(randomUUID());
  assert.equal(limited.status, 429);
  assert.match((await limited.json()).error, /Daily/);
  assert.equal((await send(randomUUID(), {}, Buffer.from('not a png'))).status, 400);
});

test('reports a missing Tripo key and model requests before the job is ready', async t => {
  const missing = await setup(t, { apiKey: '' });
  assert.equal((await missing.send(randomUUID())).status, 503);
  const { send, base, auth } = await setup(t, { status: 'running' });
  const id = randomUUID();
  await send(id);
  assert.equal((await fetch(`${base}/characters/${id}/model`, { headers: auth })).status, 409);
});
