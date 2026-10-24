import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:net';
import { spawn, execFile } from 'node:child_process';
import { once } from 'node:events';
import { promisify } from 'node:util';
import { setTimeout as delay } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';

const cwd = fileURLToPath(new URL('.', import.meta.url));

test('production Next.js serves the Swift endpoints and lobby contract', { timeout: 60_000 }, async t => {
  const reservation = createServer();
  reservation.listen(0, '127.0.0.1');
  await once(reservation, 'listening');
  const port = reservation.address().port;
  await new Promise(resolve => reservation.close(resolve));
  const base = `http://127.0.0.1:${port}`;
  const server = spawn(process.execPath, [
    'node_modules/next/dist/bin/next', 'start', '--hostname', '127.0.0.1', '--port', String(port)
  ], { cwd, stdio: ['ignore', 'pipe', 'pipe'] });
  let output = '';
  let startupError;
  server.on('error', error => { startupError = error; });
  server.stdout.on('data', chunk => { output = (output + chunk).slice(-8000); });
  server.stderr.on('data', chunk => { output = (output + chunk).slice(-8000); });
  t.after(async () => {
    if (server.exitCode !== null || server.signalCode !== null || !server.pid) return;
    const exited = once(server, 'exit');
    server.kill('SIGTERM');
    const force = setTimeout(() => server.kill('SIGKILL'), 5000);
    try { await exited; } finally { clearTimeout(force); }
  });

  let health;
  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    if (startupError) throw startupError;
    assert.equal(server.exitCode, null, output);
    try {
      health = await fetch(`${base}/health`, { signal: AbortSignal.timeout(1000) });
      if (health.ok) break;
    } catch { /* Wait for the isolated production server to listen. */ }
    await delay(100);
  }
  assert.ok(health?.ok, `Next.js did not become healthy: ${output}`);
  assert.deepEqual(await health.json(), { status: 'ok', service: 'rally' });
  assert.match(health.headers.get('cache-control'), /no-store/);
  assert.equal(health.headers.get('x-content-type-options'), 'nosniff');

  // Exercise actual Next.js rewrites and raw bodies with the same contract.
  // Fake-clock and configured-limit tests run separately in npm test.
  const environment = { ...process.env, RALLY_TEST_URL: base };
  delete environment.NODE_TEST_CONTEXT;
  const suite = await promisify(execFile)(process.execPath, ['--test', '--test-reporter=tap', 'server.test.mjs'], {
    cwd, env: environment, timeout: 25_000
  });
  assert.match(suite.stdout, /# pass 4\b/);
  t.diagnostic(suite.stdout.trim());
  const gameplay = await promisify(execFile)(process.execPath, ['--test', '--test-reporter=tap', '--test-name-pattern=HTTP game', 'game.test.mjs'], {
    cwd, env: environment, timeout: 25_000
  });
  assert.match(gameplay.stdout, /# pass 1\b/);
  t.diagnostic(gameplay.stdout.trim());

  // Both URL forms must share membership and room state.
  const created = await fetch(`${base}/rooms`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ name: 'Route check', avatar: 0 })
  });
  assert.equal(created.status, 201);
  const host = await created.json();
  const snapshot = await fetch(`${base}/api/rooms/${host.room.code}`, {
    headers: { Authorization: `Bearer ${host.token}` }
  });
  assert.equal(snapshot.status, 200);
  assert.deepEqual((await snapshot.json()).room, host.room);
});
