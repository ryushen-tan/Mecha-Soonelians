import { describe, test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { execFile, fork } from 'node:child_process';
import { createHash } from 'node:crypto';
import { once } from 'node:events';
import { setTimeout as delay } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import { hasPostgres, startPostgres, freePort } from './test-support/postgres.mjs';
import { startStorage } from './test-support/storage.mjs';
import { disguiseGLB } from './test-support/glb.mjs';

// Runs the real migrations on a throwaway PostgreSQL cluster and starts each API instance as its
// own Node process, so instances share nothing but the database and Storage, as on Vercel.

const KEY = 'sb_secret_rally_test';
const cwd = fileURLToPath(new URL('.', import.meta.url));
const running = new Set();
let db, storage;

async function startInstance(env = {}) {
  const environment = { ...process.env, RALLY_DATABASE_URL: db.apiURL, SUPABASE_URL: storage.url,
    SUPABASE_SECRET_KEY: KEY, RALLY_RATE_LIMIT: '100000', ...env };
  delete environment.NODE_TEST_CONTEXT;
  delete environment.RALLY_STORE;
  const child = fork(fileURLToPath(new URL('./test-support/instance.mjs', import.meta.url)),
    { env: environment, stdio: ['ignore', 'pipe', 'pipe', 'ipc'] });
  let output = '';
  child.stdout.on('data', chunk => { output += chunk; });
  child.stderr.on('data', chunk => { output += chunk; });
  running.add(child);
  child.once('exit', () => running.delete(child));
  const [{ port }] = await once(child, 'message');
  return {
    base: `http://127.0.0.1:${port}`,
    get output() { return output; },
    async kill() {
      if (child.exitCode !== null || child.signalCode !== null) return;
      const exited = once(child, 'exit');
      child.kill('SIGKILL');
      await exited;
    }
  };
}

async function call(instance, path, method = 'GET', body, token, contentType) {
  const binary = Buffer.isBuffer(body);
  const response = await fetch(instance.base + path, { method,
    headers: { 'Content-Type': contentType ?? (binary ? 'model/gltf-binary' : 'application/json'),
      ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: body === undefined ? undefined : binary ? body : JSON.stringify(body) });
  const data = response.headers.get('content-type')?.includes('json') ? await response.json() : Buffer.from(await response.arrayBuffer());
  return { status: response.status, data, retryAfter: response.headers.get('retry-after') };
}

// Sends each request to the next instance in turn, like a load balancer with no affinity.
async function roundRobin(instances) {
  let next = 0;
  const server = http.createServer((req, res) => {
    const target = new URL(instances[next++ % instances.length].base);
    const upstream = http.request({ host: target.hostname, port: target.port, method: req.method, path: req.url, headers: req.headers }, response => {
      res.writeHead(response.statusCode, response.headers);
      response.pipe(res);
    });
    upstream.on('error', () => { res.writeHead(502); res.end(); });
    req.pipe(upstream);
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  return { base: `http://127.0.0.1:${server.address().port}`,
    close: () => new Promise(resolve => { server.close(resolve); server.closeAllConnections(); }) };
}

async function openRoom(instance, guestInstance = instance) {
  const host = (await call(instance, '/rooms', 'POST', { name: 'Kai', avatar: 0 })).data;
  const path = `/rooms/${host.room.code}`;
  const guest = (await call(guestInstance, `${path}/join`, 'POST', { name: 'Maya', avatar: 1 })).data;
  const [{ id }] = await db.admin`select id from rally.rooms where code = ${host.room.code}`;
  return { host, guest, path, code: host.room.code, roomID: id };
}

const roomFiles = roomID => [...storage.objects.keys()].filter(path => path.startsWith(`${roomID}/`));

describe('Supabase room store', { skip: hasPostgres ? false : 'PostgreSQL (initdb) is not installed' }, () => {
  before(async () => {
    db = await startPostgres();
    storage = await startStorage({ key: KEY });
  });
  after(async () => {
    await Promise.all([...running].map(child => { const exited = once(child, 'exit'); child.kill('SIGKILL'); return exited; }));
    await storage?.close();
    await db?.close();
  });

  test('two independent API processes share one room', async () => {
    const a = await startInstance(), b = await startInstance();
    const host = await call(a, '/rooms', 'POST', { name: 'Kai', avatar: 0 });
    assert.equal(host.status, 201);
    assert.match(host.data.room.code, /^\d{6}$/);
    const path = `/rooms/${host.data.room.code}`;
    const guest = await call(b, `${path}/join`, 'POST', { name: 'Maya', avatar: 1 });
    assert.equal(guest.status, 201);
    const seen = await call(a, path, 'GET', undefined, host.data.token);
    assert.deepEqual(seen.data.room.members.map(m => [m.name, m.host, m.ready]), [['Kai', true, true], ['Maya', false, false]]);
    assert.equal(seen.data.room.createdAt, host.data.room.createdAt);
    assert.equal((await call(a, `${path}/me`, 'PATCH', { ready: true }, guest.data.token)).status, 200);
    const started = await call(b, path, 'PATCH', { status: 'started' }, host.data.token);
    assert.equal(started.data.room.status, 'started');
    assert.equal((await call(a, path, 'GET', undefined, guest.data.token)).data.room.locked, true);
    assert.equal((await call(a, `${path}/join`, 'POST', { name: 'Alex', avatar: 2 })).status, 409);
    assert.equal((await call(a, path, 'PATCH', { status: 'waiting' }, host.data.token)).data.room.members[1].ready, false);
    assert.equal((await call(b, `${path}/members/${guest.data.memberID}`, 'DELETE', undefined, host.data.token)).status, 200);
    assert.equal((await call(a, path, 'GET', undefined, guest.data.token)).status, 401);
    assert.equal((await call(b, `${path}/leave`, 'POST', {}, host.data.token)).status, 200);
    assert.equal((await call(a, path, 'GET', undefined, host.data.token)).status, 404);
    await a.kill(); await b.kill();
  });

  test('the existing HTTP contract passes when requests alternate between two processes', { timeout: 120_000 }, async () => {
    const a = await startInstance(), b = await startInstance();
    const proxy = await roundRobin([a, b]);
    const env = { ...process.env, RALLY_TEST_URL: proxy.base };
    delete env.NODE_TEST_CONTEXT;
    const run = args => promisify(execFile)(process.execPath, ['--test', '--test-reporter=tap', ...args], { cwd, env, timeout: 60_000 });
    try {
      const lobby = await run(['server.test.mjs']);
      assert.match(lobby.stdout, /# pass 4\b/);
      assert.match(lobby.stdout, /# fail 0\b/);
      const game = await run(['--test-name-pattern=HTTP game', 'game.test.mjs']);
      assert.match(game.stdout, /# pass 1\b/);
      assert.match(game.stdout, /# fail 0\b/);
    } finally {
      await proxy.close(); await a.kill(); await b.kill();
    }
  });

  test('simultaneous joins through both processes never lose a player', async () => {
    const a = await startInstance(), b = await startInstance();
    const instances = [a, b];
    const host = (await call(a, '/rooms', 'POST', { name: 'Kai', avatar: 0 })).data;
    const path = `/rooms/${host.room.code}`;
    const joins = await Promise.all(Array.from({ length: 60 }, (_, i) =>
      call(instances[i % 2], `${path}/join`, 'POST', { name: `Guest ${i}`, avatar: i % 6 })));
    assert.deepEqual(joins.map(join => join.status), Array(60).fill(201));
    const room = (await call(b, path, 'GET', undefined, host.token)).data.room;
    assert.equal(room.members.length, 61);
    assert.deepEqual(new Set(room.members.map(m => m.id)), new Set([host.memberID, ...joins.map(join => join.data.memberID)]));
    const polls = await Promise.all(joins.map((join, i) => call(instances[(i + 1) % 2], path, 'GET', undefined, join.data.token)));
    assert.ok(polls.every(poll => poll.status === 200 && poll.data.room.members.length === 61));

    // The same name in any case, from both processes at once: exactly one player gets it.
    const names = ['Echo', 'ECHO', 'echo', ' eCHo ', 'Echo', 'echO', 'ECHO', 'echo'];
    const racers = await Promise.all(names.map((name, i) => call(instances[i % 2], `${path}/join`, 'POST', { name, avatar: 0 })));
    assert.equal(racers.filter(racer => racer.status === 201).length, 1);
    assert.equal(racers.filter(racer => racer.status === 409).length, names.length - 1);
    const [{ count }] = await db.admin`select count(*)::int as count from rally.members m join rally.rooms r on r.id = m.room_id where r.code = ${host.room.code}`;
    assert.equal(count, 62);

    // Rooms created at the same moment on both processes get distinct codes.
    const rooms = await Promise.all(Array.from({ length: 30 }, (_, i) => call(instances[i % 2], '/rooms', 'POST', { name: `Host ${i}`, avatar: 0 })));
    assert.ok(rooms.every(created => created.status === 201));
    assert.equal(new Set(rooms.map(created => created.data.room.code)).size, 30);
    await a.kill(); await b.kill();
  });

  test('simultaneous game actions through both processes are all applied', async () => {
    const a = await startInstance(), b = await startInstance();
    const instances = [a, b];
    const host = (await call(a, '/rooms', 'POST', { name: 'Kai', avatar: 0 })).data;
    const path = `/rooms/${host.room.code}`;
    const hiders = [];
    for (let i = 0; i < 8; i++) {
      const hider = (await call(instances[i % 2], `${path}/join`, 'POST', { name: `Hider ${i}`, avatar: i % 6 })).data;
      assert.equal((await call(instances[i % 2], `${path}/disguise`, 'POST', disguiseGLB(), hider.token)).status, 200);
      assert.equal((await call(instances[(i + 1) % 2], `${path}/me`, 'PATCH', { ready: true }, hider.token)).status, 200);
      hiders.push(hider);
    }
    const start = await call(b, `${path}/game`, 'POST', { action: 'start', mode: 'basic', preparationSeconds: 0, autoTauntSeconds: 0, room: { surfaces: [] } }, host.token);
    assert.equal(start.status, 200);
    // Each taunt rewrites the shared game state; without the room lock some would be lost.
    const taunts = await Promise.all(hiders.map((hider, i) => call(instances[i % 2], `${path}/game`, 'POST', { action: 'taunt' }, hider.token)));
    assert.deepEqual(taunts.map(taunt => taunt.status), Array(8).fill(200));
    const game = (await call(a, `${path}/game`, 'GET', undefined, host.token)).data.game;
    assert.equal(game.phase, 'hunting');
    assert.deepEqual(new Set(game.taunts.map(taunt => taunt.id)), new Set(hiders.map(hider => hider.memberID)));
    await a.kill(); await b.kill();
  });

  test('membership and published disguises survive restarting every API process', async () => {
    const a = await startInstance(), b = await startInstance();
    const { host, guest, path } = await openRoom(a, b);
    const glb = disguiseGLB();
    const published = await call(a, `${path}/disguise`, 'POST', glb, guest.token);
    assert.equal(published.status, 200);
    const [row] = await db.admin`select version, storage_path, size_bytes from rally.disguises where member_id = ${guest.memberID}`;
    assert.equal(row.version, published.data.version);
    assert.equal(row.size_bytes, glb.length);
    assert.deepEqual(storage.objects.get(row.storage_path).data, glb);

    await a.kill(); await b.kill();
    const c = await startInstance();
    const restored = await call(c, path, 'GET', undefined, host.token);
    assert.equal(restored.status, 200);
    assert.deepEqual(restored.data.room.members.map(m => m.id), [host.memberID, guest.memberID]);
    assert.deepEqual(restored.data.room.game.published, [guest.memberID]);
    assert.equal((await call(c, path, 'GET', undefined, guest.token)).status, 200);
    const model = await call(c, `${path}/disguise/${guest.memberID}`, 'GET', undefined, guest.token);
    assert.equal(model.status, 200);
    assert.deepEqual(model.data, glb);
    await c.kill();
  });

  test('disguise uploads keep validation and phase rules, and stored files follow their rows', async () => {
    const a = await startInstance(), b = await startInstance();
    const { host, guest, path, roomID } = await openRoom(a, b);
    const first = disguiseGLB();
    assert.equal((await call(a, `${path}/disguise`, 'POST', first)).status, 401);
    assert.equal((await call(a, `${path}/disguise`, 'POST', first, guest.token, 'application/octet-stream')).status, 415);
    assert.equal((await call(a, `${path}/disguise`, 'POST', Buffer.alloc(64, 1), guest.token)).status, 400);
    assert.equal((await call(a, `${path}/disguise`, 'POST', Buffer.alloc(20 * 1024 * 1024 + 1), guest.token)).status, 413);
    assert.deepEqual(roomFiles(roomID), []);

    // Replacing a disguise deletes the old file.
    assert.equal((await call(a, `${path}/disguise`, 'POST', first, guest.token)).status, 200);
    const [{ storage_path: firstPath }] = await db.admin`select storage_path from rally.disguises where member_id = ${guest.memberID}`;
    const second = disguiseGLB([{ id: '0', min: [1, 0, 1], max: [1.6, 1.8, 1.6] }]);
    assert.equal((await call(b, `${path}/disguise`, 'POST', second, guest.token)).status, 200);
    const [{ storage_path: secondPath }] = await db.admin`select storage_path from rally.disguises where member_id = ${guest.memberID}`;
    assert.notEqual(secondPath, firstPath);
    assert.deepEqual(roomFiles(roomID), [secondPath]);

    // Visibility during preparation is decided by whichever instance serves the request.
    await call(b, `${path}/me`, 'PATCH', { ready: true }, guest.token);
    const start = await call(a, `${path}/game`, 'POST', { action: 'start', mode: 'basic', preparationSeconds: 30, room: { surfaces: [] } }, host.token);
    assert.equal(start.status, 200);
    const [stored] = await db.admin`select jsonb_typeof(g.state) as state, jsonb_typeof(g.surfaces) as surfaces, jsonb_typeof(d.boxes) as boxes
      from rally.games g, rally.disguises d where g.room_id = ${roomID} and d.member_id = ${guest.memberID}`;
    assert.deepEqual({ ...stored }, { state: 'object', surfaces: 'array', boxes: 'array' });
    assert.equal((await call(b, `${path}/disguise/${guest.memberID}`, 'GET', undefined, host.token)).status, 403);
    const own = await call(a, `${path}/disguise/${guest.memberID}`, 'GET', undefined, guest.token);
    assert.equal(own.status, 200);
    assert.deepEqual(own.data, second);

    // A hunter's upload is stored before the phase check, then discarded.
    assert.equal((await call(b, `${path}/disguise`, 'POST', first, host.token)).status, 403);
    assert.deepEqual(roomFiles(roomID), [secondPath]);
    assert.equal((await db.admin`select 1 from rally.disguises where member_id = ${host.memberID}`).length, 0);

    // Closing the room removes its files.
    assert.equal((await call(a, `${path}/leave`, 'POST', {}, host.token)).status, 200);
    assert.deepEqual(roomFiles(roomID), []);
    assert.equal((await db.admin`select count(*)::int as count from rally.storage_trash`)[0].count, 0);
    await a.kill(); await b.kill();
  });

  test('expiry is enforced on every request, without waiting for scheduled cleanup', async () => {
    const a = await startInstance({ RALLY_MEMBER_TTL_MS: '1000' }), b = await startInstance({ RALLY_MEMBER_TTL_MS: '1000' });
    const { host, guest, path, code } = await openRoom(a, b);
    for (let i = 0; i < 5; i++) {
      await delay(300);
      assert.equal((await call(i % 2 ? a : b, path, 'GET', undefined, host.token)).status, 200);
    }
    assert.equal((await call(b, path, 'GET', undefined, guest.token)).status, 401);
    assert.deepEqual((await call(a, path, 'GET', undefined, host.token)).data.room.members.map(m => m.name), ['Kai']);
    await delay(1500);
    assert.equal((await call(b, path, 'GET', undefined, host.token)).status, 404);
    assert.equal((await db.admin`select 1 from rally.rooms where code = ${code}`).length, 0);

    // The scheduled job applies the same rules to rooms nobody asks about, and their files are
    // deleted the next time an instance creates a room.
    const idle = await openRoom(a);
    assert.equal((await call(a, `${idle.path}/disguise`, 'POST', disguiseGLB(), idle.guest.token)).status, 200);
    const [{ closed }] = await db.admin`select rally.cleanup_expired(now() + interval '1 hour') as closed`;
    assert.ok(closed >= 1);
    assert.equal((await db.admin`select 1 from rally.rooms where code = ${idle.code}`).length, 0);
    assert.equal(roomFiles(idle.roomID).length, 1);
    assert.equal((await call(b, '/rooms', 'POST', { name: 'Next', avatar: 0 })).status, 201);
    assert.deepEqual(roomFiles(idle.roomID), []);
    await a.kill(); await b.kill();
  });

  test('database and Storage outages return retryable 503s, never 404 or 401', { timeout: 60_000 }, async () => {
    const a = await startInstance();
    const { host, guest, path } = await openRoom(a);
    await db.pause();
    try {
      for (const [route, method, body, token] of [[path, 'GET', undefined, host.token], [`${path}/game`, 'GET', undefined, guest.token],
        [`${path}/join`, 'POST', { name: 'Late', avatar: 2 }], ['/rooms', 'POST', { name: 'New', avatar: 0 }],
        [`${path}/leave`, 'POST', {}, guest.token], [`${path}/disguise/${guest.memberID}`, 'GET', undefined, guest.token]]) {
        const response = await call(a, route, method, body, token);
        assert.equal(response.status, 503, `${method} ${route}`);
        assert.equal(response.retryAfter, '2');
        assert.match(response.data.error, /temporarily unavailable/);
      }
    } finally { await db.resume(); }
    // The outage cost nobody their place: the failed leave did not happen either.
    let back;
    for (let attempt = 0; attempt < 10 && back?.status !== 200; attempt++) {
      if (attempt) await delay(200);
      back = await call(a, path, 'GET', undefined, guest.token);
    }
    assert.equal(back.status, 200);
    assert.equal(back.data.room.members.length, 2);

    const unreachable = await startInstance({ RALLY_DATABASE_URL: `postgres://rally_api:x@127.0.0.1:${await freePort()}/postgres` });
    assert.equal((await call(unreachable, path, 'GET', undefined, host.token)).status, 503);
    assert.equal((await call(unreachable, '/rooms', 'POST', { name: 'New', avatar: 0 })).status, 503);

    // Missing configuration refuses requests instead of silently keeping rooms in memory.
    const unconfigured = await startInstance({ RALLY_DATABASE_URL: '' });
    assert.equal((await call(unconfigured, '/rooms', 'POST', { name: 'New', avatar: 0 })).status, 503);
    assert.match(unconfigured.output, /RALLY_DATABASE_URL/);

    // Without Storage, rooms keep working and publishing fails retryably.
    const noStorage = await startInstance({ SUPABASE_URL: `http://127.0.0.1:${await freePort()}` });
    const upload = await call(noStorage, `${path}/disguise`, 'POST', disguiseGLB(), guest.token);
    assert.equal(upload.status, 503);
    assert.equal(upload.retryAfter, '2');
    assert.equal((await call(noStorage, path, 'GET', undefined, guest.token)).status, 200);
    for (const instance of [a, unreachable, unconfigured, noStorage]) await instance.kill();
  });

  test('tokens are stored only as hashes, and client roles cannot reach room data', async () => {
    const a = await startInstance();
    const { host, guest } = await openRoom(a);
    const [member] = await db.admin`select token_hash from rally.members where id = ${host.memberID}`;
    assert.equal(member.token_hash, createHash('sha256').update(host.token).digest('hex'));
    for (const table of ['rooms', 'members', 'games', 'disguises', 'storage_trash']) {
      const dump = JSON.stringify(await db.admin.unsafe(`select * from rally.${table}`));
      assert.ok(!dump.includes(host.token) && !dump.includes(guest.token), table);
    }

    const tables = await db.admin`select relname, relrowsecurity from pg_class
      where relnamespace = 'rally'::regnamespace and relkind = 'r' order by relname`;
    assert.deepEqual(tables.map(t => [t.relname, t.relrowsecurity]),
      [['disguises', true], ['games', true], ['members', true], ['rooms', true], ['storage_trash', true]]);
    for (const role of ['anon', 'authenticated', 'service_role']) {
      const [access] = await db.admin`select
        has_schema_privilege(${role}, 'rally', 'usage') as schema,
        bool_or(has_table_privilege(${role}, c.oid, 'select,insert,update,delete')) as tables,
        has_function_privilege(${role}, 'rally.cleanup_expired(timestamptz, interval, interval)', 'execute') as cleanup,
        has_function_privilege(${role}, 'rally.trash_disguise_file()', 'execute') as trigger,
        has_function_privilege(${role}, 'rally.room_load(text)', 'execute') or has_function_privilege(${role}, 'rally.room_save(uuid, jsonb)', 'execute')
          or has_function_privilege(${role}, 'rally.room_create(bigint, bigint, bigint, integer, text[])', 'execute') as rooms
        from pg_class c where c.relnamespace = 'rally'::regnamespace and c.relkind in ('r', 'S')`;
      assert.deepEqual(access, { schema: false, tables: false, cleanup: false, trigger: false, rooms: false }, role);
      await assert.rejects(db.admin.begin(async tx => {
        await tx.unsafe(`set local role ${role}`);
        await tx`select * from rally.members`;
      }), { code: '42501' });
    }
    // The API role uses its tables but cannot change the schema.
    await assert.rejects(db.admin.begin(async tx => {
      await tx.unsafe('set local role rally_api');
      await tx`create table rally.extra (id int)`;
    }), { code: '42501' });
    const [role] = await db.admin`select rolconfig from pg_roles where rolname = 'rally_api'`;
    assert.ok(role.rolconfig.includes('statement_timeout=5s'));
    const [bucket] = await db.admin`select public, file_size_limit, allowed_mime_types from storage.buckets where id = 'rally-disguises'`;
    assert.deepEqual({ ...bucket }, { public: false, file_size_limit: '20971520', allowed_mime_types: ['model/gltf-binary'] });
    await a.kill();
  });
});
