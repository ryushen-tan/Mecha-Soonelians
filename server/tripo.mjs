import http from 'node:http';
import { createHash, timingSafeEqual } from 'node:crypto';
import { mkdirSync, readdirSync, readFileSync, writeFileSync, renameSync, existsSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';

const fail = (status, message) => { throw Object.assign(new Error(message), { status }); };
const MAX_IMAGE = 5 * 1024 * 1024;
const MAX_MODEL = 100 * 1024 * 1024;
const ID = /^[a-f0-9-]{36}$/i;

export function validatePNG(data) {
  if (data.length < 33 || data.length > MAX_IMAGE ||
      data.subarray(0, 8).toString('hex') !== '89504e470d0a1a0a' || data.toString('ascii', 12, 16) !== 'IHDR') {
    fail(400, 'Send a PNG cutout smaller than 5 MB.');
  }
  const width = data.readUInt32BE(16);
  const height = data.readUInt32BE(20);
  if (!width || !height || width > 4096 || height > 4096) fail(400, 'PNG dimensions must be between 1 and 4096 pixels.');
}

export function validateModelURL(value) {
  const url = new URL(value);
  if (url.protocol !== 'https:' || url.username || url.password || (url.port && url.port !== '443') ||
      !['tripo3d.ai', 'tripo3d.com'].some(domain => url.hostname === domain || url.hostname.endsWith('.' + domain))) {
    throw new Error('Tripo returned an unsupported model download host.');
  }
  return url;
}

export function createTripoAPI(key, fetcher = fetch) {
  async function request(path, body) {
    const multipart = body instanceof FormData;
    const response = await fetcher('https://openapi.tripo3d.ai/v3/' + path, {
      method: body ? 'POST' : 'GET', redirect: 'error', signal: AbortSignal.timeout(90_000),
      headers: { Authorization: `Bearer ${key}`, ...(body && !multipart ? { 'Content-Type': 'application/json' } : {}) },
      body: body ? (multipart ? body : JSON.stringify(body)) : undefined
    });
    if (!response.ok) throw new Error(`Tripo request failed (HTTP ${response.status}). Check your API key, credits and dashboard.`);
    const result = await response.json();
    if (result.code !== 0 || !result.data) throw new Error(`Tripo rejected the request (code ${Number(result.code)}). Check the Tripo dashboard.`);
    return result.data;
  }
  return {
    async upload(data) {
      const form = new FormData();
      form.append('file', new Blob([data], { type: 'image/png' }), 'person.png');
      const result = await request('files', form);
      if (typeof result.file_token !== 'string') throw new Error('Tripo did not return an upload token.');
      return result.file_token;
    },
    create: request,
    task: id => request('tasks/' + encodeURIComponent(id)),
    async download(value) {
      const response = await fetcher(validateModelURL(value), { redirect: 'error', signal: AbortSignal.timeout(120_000) });
      if (!response.ok || Number(response.headers.get('content-length')) > MAX_MODEL) throw new Error('Model download failed or exceeds 100 MB.');
      const chunks = [];
      let size = 0;
      for await (const chunk of response.body) {
        size += chunk.length;
        if (size > MAX_MODEL) throw new Error('Model exceeds the 100 MB mobile limit.');
        chunks.push(chunk);
      }
      const data = Buffer.concat(chunks);
      if (data.length < 12 || data.toString('ascii', 0, 4) !== 'glTF' || data.readUInt32LE(4) !== 2) throw new Error('Tripo did not return a GLB 2.0 model.');
      return data;
    }
  };
}

export function createCharacterServer({ apiKey = process.env.TRIPO_API_KEY || process.env.TRIPO_AI_API_KEY, accessToken = process.env.TRIPO_PROXY_TOKEN,
  directory = resolve('artifacts/tripo'), api = createTripoAPI(apiKey), pollMS = 3000,
  maxJobsPerDay = 10, maxActive = 2 } = {}) {
  mkdirSync(directory, { recursive: true, mode: 0o700 });
  const jobs = new Map();
  const active = new Set();
  let closed = false;
  const folder = id => join(directory, id);
  function persist(job) {
    writeFileSync(join(folder(job.id), 'job.tmp'), JSON.stringify(job), { mode: 0o600 });
    renameSync(join(folder(job.id), 'job.tmp'), join(folder(job.id), 'job.json'));
  }
  const snapshot = job => ({ id: job.id, status: job.status, stage: job.stage, progress: job.progress,
    rigged: job.rigged ?? false, warning: job.warning ?? null, error: job.error ?? null,
    credits: Object.values(job.results).reduce((total, result) => total + (Number(result.credits_consumed) || 0), 0) });

  async function stage(job, name, endpoint, body) {
    if (job.results[name]) return job.results[name];
    job.stage = name;
    job.progress = 0;
    if (!job.tasks[name]) {
      if (job.submitting === name) throw new Error('Submission was interrupted. Check Tripo before starting another paid generation.');
      job.submitting = name;
      persist(job);
      const result = await api.create(endpoint, body);
      if (typeof result.task_id !== 'string') throw new Error('Tripo did not return a task ID. Check the dashboard before retrying.');
      job.tasks[name] = result.task_id;
      job.submitting = null;
      persist(job);
    }
    const deadline = Date.now() + 30 * 60_000;
    let failures = 0;
    while (!closed && Date.now() < deadline) {
      let result;
      try { result = await api.task(job.tasks[name]); failures = 0; }
      catch (error) {
        if (++failures >= 5) throw error;
        await delay(pollMS);
        continue;
      }
      job.progress = Math.min(100, Math.max(0, Number(result.progress) || 0));
      persist(job);
      if (result.status === 'success') {
        job.results[name] = result;
        persist(job);
        return result;
      }
      if (['failed', 'cancelled', 'banned', 'expired'].includes(result.status)) throw new Error(`Tripo ${name} ${result.status}. Check task ${job.tasks[name]} in the dashboard.`);
      await delay(pollMS);
    }
    throw new Error('Stopped waiting. The Tripo task may still complete; no duplicate task was submitted.');
  }

  async function run(job) {
    if (active.has(job.id)) return;
    active.add(job.id);
    try {
      if (!job.fileToken) {
        job.fileToken = await api.upload(readFileSync(join(folder(job.id), 'input.png')));
        persist(job);
      }
      const generated = await stage(job, 'generating', 'generation/image-to-model', {
        input: job.fileToken, model: 'v3.1-20260211', face_limit: 20000,
        texture: true, pbr: true, texture_quality: 'standard', orientation: 'align_image'
      });
      const meshPath = join(folder(job.id), 'mesh.glb');
      if (!existsSync(meshPath)) writeFileSync(meshPath, await api.download(generated.output?.model_url));
      try {
        const check = await stage(job, 'checking', 'animations/rig-check', { input: job.tasks.generating });
        if (check.output?.riggable !== true || check.output?.rig_type !== 'biped') {
          job.warning = 'Tripo could not confirm a humanoid rig. You can rotate the mesh, but not pose its joints. Try a standing full-body photo.';
        } else {
          const rig = await stage(job, 'rigging', 'animations/rig', {
            input: job.tasks.generating, model: 'v3.0-20260909', rig_type: 'biped', spec: 'mixamo', out_format: 'glb'
          });
          writeFileSync(join(folder(job.id), 'rigged.glb'), await api.download(rig.output?.model_url));
          job.rigged = true;
        }
      } catch (error) {
        if (closed) return;
        job.warning = 'Mesh is ready, but rigging did not complete. ' + error.message;
      }
      job.status = 'ready';
      job.stage = 'ready';
      job.progress = 100;
    } catch (error) {
      if (closed) return;
      job.status = 'failed';
      job.error = error.message;
    } finally {
      persist(job);
      active.delete(job.id);
    }
  }

  for (const name of readdirSync(directory)) {
    if (!ID.test(name)) continue;
    try {
      const job = JSON.parse(readFileSync(join(folder(name), 'job.json')));
      if (job.id === name) jobs.set(name, job);
    } catch {}
  }

  const server = http.createServer(async (req, res) => {
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    const send = (status, body) => { res.writeHead(status, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(body)); };
    try {
      if (req.headers.origin) fail(403, 'Browser requests are not allowed. Use the native app.');
      const local = ['127.0.0.1', '::1', '::ffff:127.0.0.1'].includes(req.socket.remoteAddress);
      const host = new URL('http://' + req.headers.host).hostname;
      if (accessToken) {
        const supplied = createHash('sha256').update(req.headers.authorization ?? '').digest();
        const expected = createHash('sha256').update(`Bearer ${accessToken}`).digest();
        if (!timingSafeEqual(supplied, expected)) fail(401, 'Enter the 3D server access token, not your Tripo API key.');
      } else if (!local || !['localhost', '127.0.0.1', '[::1]'].includes(host)) {
        fail(403, 'Remote use requires TRIPO_PROXY_TOKEN on the server.');
      }
      const url = new URL(req.url, 'http://localhost');
      if (req.method === 'GET' && url.pathname === '/health') return send(200, { configured: Boolean(apiKey), service: 'rally-tripo' });
      if (req.method === 'POST' && url.pathname === '/characters') {
        if (!apiKey) fail(503, 'Add TRIPO_API_KEY to the project .env and restart the 3D server.');
        const id = req.headers['x-request-id'];
        if (typeof id !== 'string' || !ID.test(id)) fail(400, 'A UUID X-Request-ID is required.');
        if (req.headers['content-type'] !== 'image/png') fail(415, 'Send image/png.');
        const chunks = [];
        let size = 0;
        for await (const chunk of req) {
          size += chunk.length;
          if (size > MAX_IMAGE) fail(413, 'Cutout exceeds 5 MB.');
          chunks.push(chunk);
        }
        const data = Buffer.concat(chunks);
        validatePNG(data);
        const hash = createHash('sha256').update(data).digest('hex');
        const existing = jobs.get(id);
        if (existing) {
          if (existing.hash !== hash) fail(409, 'This request ID already belongs to another cutout.');
          return send(200, snapshot(existing));
        }
        if (active.size >= maxActive) fail(429, 'Two characters are already processing. Wait for them to finish.');
        if ([...jobs.values()].filter(job => Date.now() - job.createdAt < 86400_000).length >= maxJobsPerDay) fail(429, 'Daily development generation limit reached.');
        const job = { id, hash, createdAt: Date.now(), status: 'working', stage: 'uploading', progress: 0, tasks: {}, results: {} };
        mkdirSync(folder(id), { mode: 0o700 });
        writeFileSync(join(folder(id), 'input.png'), data, { mode: 0o600 });
        persist(job);
        jobs.set(id, job);
        void run(job);
        return send(202, snapshot(job));
      }
      const match = url.pathname.match(/^\/characters\/([a-f0-9-]{36})(?:\/(model|input))?$/i);
      const job = match && jobs.get(match[1]);
      if (!job) fail(404, 'Character not found on this server.');
      if (req.method !== 'GET') fail(405, 'Unsupported method.');
      if (!match[2]) return send(200, snapshot(job));
      if (match[2] === 'model' && job.status !== 'ready') fail(409, 'The model is not ready.');
      const input = match[2] === 'input';
      const file = input ? 'input.png' : job.rigged ? 'rigged.glb' : 'mesh.glb';
      res.writeHead(200, { 'Content-Type': input ? 'image/png' : 'model/gltf-binary' });
      res.end(readFileSync(join(folder(job.id), file)));
    } catch (error) {
      if (!res.headersSent) send(error.status ?? 500, { error: error.status ? error.message : '3D server error. Check the local server configuration.' });
      else res.destroy();
    }
  });
  server.requestTimeout = 30_000;
  server.on('close', () => { closed = true; });
  server.on('listening', () => {
    if (apiKey) for (const job of jobs.values()) if (job.status === 'working') void run(job);
  });
  return server;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const host = process.env.TRIPO_HOST ?? '127.0.0.1';
  const port = Number(process.env.TRIPO_PORT ?? 3001);
  if (host !== '127.0.0.1' && !process.env.TRIPO_PROXY_TOKEN) throw new Error('Set TRIPO_PROXY_TOKEN before exposing the 3D server to your network.');
  createCharacterServer().listen(port, host, () => console.log(`3D server listening on ${host}:${port}. Tripo key configured: ${Boolean(process.env.TRIPO_API_KEY || process.env.TRIPO_AI_API_KEY)}`));
}
