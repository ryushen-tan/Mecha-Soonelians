import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { createCharacterServer, createTripoAPI, validatePNG, validateModelURL } from './tripo.mjs';

const png = readFileSync(new URL('../TestFixtures/HumanDepth/human-1-cutout.png', import.meta.url));
const glb = Buffer.alloc(12);
glb.write('glTF');
glb.writeUInt32LE(2, 4);
glb.writeUInt32LE(12, 8);

async function setup(t, options = {}) {
  const directory = mkdtempSync(join(tmpdir(), 'rally-tripo-'));
  const calls = [];
  const api = {
    upload: async () => 'file_test',
    create: async (path, body) => { calls.push({ path, body }); return { task_id: 'task_' + calls.length }; },
    task: async id => ({ status: 'success', progress: 100, credits_consumed: 1,
      output: id === 'task_2' ? { riggable: options.riggable ?? true, rig_type: 'biped' } : { model_url: 'https://cdn.tripo3d.ai/test.glb' } }),
    download: async () => glb
  };
  const server = createCharacterServer({ directory, api, apiKey: 'test-key', pollMS: 1, ...options });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => {
    await new Promise(resolve => { server.close(resolve); server.closeAllConnections(); });
    rmSync(directory, { recursive: true, force: true });
  });
  const base = `http://127.0.0.1:${server.address().port}`;
  const send = (id, headers = {}, data = png) => fetch(base + '/characters', {
    method: 'POST', headers: { 'Content-Type': 'image/png', 'X-Request-ID': id, ...headers }, body: data
  });
  const wait = async id => {
    for (let attempt = 0; attempt < 100; attempt++) {
      const job = await (await fetch(base + '/characters/' + id)).json();
      if (job.status !== 'working') return job;
      await new Promise(resolve => setTimeout(resolve, 5));
    }
    throw new Error('Job did not finish');
  };
  return { send, wait, base, calls, directory };
}

test('generates, checks and rigs once; request replay does not spend credits twice', async t => {
  const { send, wait, base, calls } = await setup(t);
  const id = randomUUID();
  assert.equal((await send(id)).status, 202);
  const job = await wait(id);
  assert.equal(job.status, 'ready');
  assert.equal(job.rigged, true);
  assert.equal(job.credits, 3);
  assert.equal((await send(id)).status, 200);
  assert.deepEqual(calls.map(call => call.path), ['generation/image-to-model', 'animations/rig-check', 'animations/rig']);
  assert.equal(calls[2].body.model, 'v3.0-20260909');
  assert.equal(calls[2].body.spec, 'mixamo');
  assert.deepEqual(Buffer.from(await (await fetch(base + '/characters/' + id + '/model')).arrayBuffer()), glb);
  assert.equal(JSON.stringify(job).includes('file_test'), false);
  const changed = Buffer.from(png);
  changed[changed.length - 1] ^= 1;
  assert.equal((await send(id, {}, changed)).status, 409);
});

test('keeps the generated mesh when rig-check fails without paying for rigging', async t => {
  const { send, wait, calls } = await setup(t, { riggable: false });
  const id = randomUUID();
  await send(id);
  const job = await wait(id);
  assert.equal(job.status, 'ready');
  assert.equal(job.rigged, false);
  assert.match(job.warning, /standing/);
  assert.equal(calls.length, 2);
});

test('X-Rig: 0 returns the plain mesh without rig-check or rigging', async t => {
  const { send, wait, base, calls } = await setup(t);
  const id = randomUUID();
  assert.equal((await send(id, { 'X-Rig': '0' })).status, 202);
  const job = await wait(id);
  assert.equal(job.status, 'ready');
  assert.equal(job.rigged, false);
  assert.deepEqual(calls.map(call => call.path), ['generation/image-to-model']);
  assert.deepEqual(Buffer.from(await (await fetch(base + '/characters/' + id + '/model')).arrayBuffer()), glb);
});

test('requires proxy token when configured and rejects browser origins', async t => {
  const { send, calls } = await setup(t, { accessToken: 'local-test-token' });
  assert.equal((await send(randomUUID())).status, 401);
  assert.equal((await send(randomUUID(), { Origin: 'https://example.com', Authorization: 'Bearer local-test-token' })).status, 403);
  assert.equal(calls.length, 0);
});

test('missing API key, invalid PNG and budget limits fail before paid calls', async t => {
  const missing = await setup(t, { apiKey: '' });
  assert.equal((await missing.send(randomUUID())).status, 503);
  assert.equal(missing.calls.length, 0);
  const limited = await setup(t, { maxJobsPerDay: 0 });
  assert.equal((await limited.send(randomUUID())).status, 429);
  assert.equal((await limited.send(randomUUID(), {}, Buffer.from('not png'))).status, 400);
  assert.equal(limited.calls.length, 0);
});

test('validates PNG dimensions and restricts model download hosts', () => {
  assert.doesNotThrow(() => validatePNG(png));
  const large = Buffer.from(png);
  large.writeUInt32BE(99999, 16);
  assert.throws(() => validatePNG(large));
  assert.doesNotThrow(() => validateModelURL('https://cdn.tripo3d.ai/model.glb'));
  for (const url of ['http://cdn.tripo3d.ai/model.glb', 'https://127.0.0.1/a', 'https://tripo3d.ai.evil.test/a', 'https://user:pass@cdn.tripo3d.ai/a']) {
    assert.throws(() => validateModelURL(url));
  }
});

test('API uses v3 contract and never attaches Tripo credentials to asset downloads', async () => {
  const calls = [];
  const api = createTripoAPI('never-print-this', async (url, options) => {
    calls.push({ url: String(url), options });
    if (String(url).includes('/files')) return Response.json({ code: 0, data: { file_token: 'file_fixture' } });
    if (String(url).includes('/tasks/')) return Response.json({ code: 0, data: { status: 'success' } });
    return new Response(glb);
  });
  assert.equal(await api.upload(png), 'file_fixture');
  await api.task('task_fixture');
  await api.download('https://cdn.tripo3d.ai/a.glb');
  assert.equal(calls[0].url, 'https://openapi.tripo3d.ai/v3/files');
  assert.equal(calls[0].options.body.get('file').type, 'image/png');
  assert.equal(calls[1].url, 'https://openapi.tripo3d.ai/v3/tasks/task_fixture');
  assert.equal(calls[2].options.headers, undefined);
  assert.equal(calls[2].options.redirect, 'error');
});
