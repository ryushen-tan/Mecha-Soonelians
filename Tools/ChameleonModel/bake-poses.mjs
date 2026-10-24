// Bakes every pose of the chameleon body into MechaSoonelians/Capture/CharacterViewer/chameleon-poses.{json,bin},
// so the game can switch poses instantly in AR. Run after rebuilding the viewer (npm run build in
// Tools/CharacterViewer): node bake-poses.mjs [path to Chrome]
//
// chameleon-poses.bin (little-endian): uvs (vertexCount × 2 float32, USD st: v points up),
// triangle indices (triangleCount × 3 uint32), then for each pose its positions (vertexCount × 3 float32).
import { spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const viewer = resolve(import.meta.dirname, '../../MechaSoonelians/Capture/CharacterViewer');
const chrome = process.argv[2] ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const profile = mkdtempSync(join(tmpdir(), 'bake-poses-'));
const port = 9400 + Math.floor(Math.random() * 400);
const browser = spawn(chrome, ['--headless=new', `--remote-debugging-port=${port}`, `--user-data-dir=${profile}`,
  '--use-angle=swiftshader', '--enable-unsafe-swiftshader', 'about:blank'], { stdio: 'ignore' });

try {
  let page;
  for (let attempt = 0; !page && attempt < 50; attempt++) {
    await new Promise(r => setTimeout(r, 200));
    page = await fetch(`http://127.0.0.1:${port}/json`).then(r => r.json()).then(pages => pages.find(p => p.type === 'page')).catch(() => null);
  }
  if (!page) throw new Error('Chrome did not start.');
  const socket = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise(r => socket.addEventListener('open', r));
  let nextID = 0;
  const call = (method, params = {}) => new Promise((done, fail) => {
    const id = ++nextID;
    const listener = event => {
      const message = JSON.parse(event.data);
      if (message.id !== id) return;
      socket.removeEventListener('message', listener);
      message.error ? fail(new Error(message.error.message)) : done(message.result);
    };
    socket.addEventListener('message', listener);
    socket.send(JSON.stringify({ id, method, params }));
  });
  const evaluate = async expression => {
    const { result, exceptionDetails } = await call('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
    if (exceptionDetails) throw new Error(exceptionDetails.exception?.description ?? exceptionDetails.text);
    return result.value;
  };

  // The viewer talks to the app through webkit message handlers; collect them instead.
  await call('Page.addScriptToEvaluateOnNewDocument', { source:
    'window.__messages = []; window.webkit = { messageHandlers: { character: { postMessage: m => window.__messages.push(m) } } };' });
  await call('Page.enable');
  await call('Page.navigate', { url: `file://${viewer}/index.html` });
  await new Promise(r => setTimeout(r, 3000));
  const body = readFileSync(join(viewer, 'chameleon-base.glb')).toString('base64');
  await evaluate(`window.characterViewer.load(${JSON.stringify(body)}, '')`);
  await evaluate('new Promise(r => setTimeout(r, 1500))');
  const baked = await evaluate('window.characterViewer.bakePoses()');

  // Keep only the vertices the triangles use, renumbered in order.
  const renumber = new Map();
  const index = baked.index.map(old => {
    if (!renumber.has(old)) renumber.set(old, renumber.size);
    return renumber.get(old);
  });
  const used = [...renumber.keys()];
  const vertexCount = used.length, triangleCount = index.length / 3;
  const uvs = Buffer.from(new Float32Array(used.flatMap(i => [baked.uv[i * 2], 1 - baked.uv[i * 2 + 1]])).buffer);
  const indices = Buffer.from(new Uint32Array(index).buffer);
  const positions = baked.positions.map(p => Buffer.from(new Float32Array(used.flatMap(i => [p[i * 3], p[i * 3 + 1], p[i * 3 + 2]])).buffer));
  writeFileSync(join(viewer, 'chameleon-poses.bin'), Buffer.concat([uvs, indices, ...positions]));
  writeFileSync(join(viewer, 'chameleon-poses.json'), JSON.stringify({ vertexCount, triangleCount, poses: baked.poses }, null, 1) + '\n');
  console.log(`Baked ${baked.poses.length} poses: ${vertexCount} vertices, ${triangleCount} triangles.`);
  socket.close();
} finally {
  const exited = new Promise(r => browser.once('exit', r));
  browser.kill();
  await exited;
  rmSync(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
}
