import { createHash, timingSafeEqual } from 'node:crypto';
import { createTripoAPI, validatePNG } from './tripo-api.mjs';

// Serverless version of tripo.mjs. Nothing runs between requests: each status poll
// from the app checks Tripo once and, when a stage finishes, submits the next one.
// Paid submissions are claimed with a conditional write first, so concurrent polls
// never start the same Tripo task twice.

const MAX_IMAGE = 5 * 1024 * 1024;
const ID = /^[a-f0-9-]{36}$/i;
const DAY = 86400_000;
const STAGE_DEADLINE = 30 * 60_000;
const STALE_SUBMISSION = 2 * 60_000;
const ENDED = ['failed', 'cancelled', 'banned', 'expired'];
const fail = (status, message) => { throw Object.assign(new Error(message), { status }); };

export class Conflict extends Error {}

export function createCharactersHandler({ apiKey = process.env.TRIPO_API_KEY || process.env.TRIPO_AI_API_KEY,
  accessToken = process.env.TRIPO_PROXY_TOKEN, store, api = createTripoAPI(apiKey),
  maxJobsPerDay = Number(process.env.TRIPO_DAILY_LIMIT) || 100, now = Date.now } = {}) {

  const snapshot = job => ({ id: job.id, status: job.status, stage: job.stage, progress: job.progress,
    rigged: job.rigged ?? false, warning: job.warning ?? null, error: job.error ?? null,
    credits: Object.values(job.results).reduce((total, result) => total + (Number(result.credits) || 0), 0) });

  // Writes the job only if nobody else changed it since it was read; throws Conflict otherwise.
  const etags = new WeakMap();
  const load = async id => {
    const found = await store.read(id);
    if (found) etags.set(found.job, found.etag);
    return found?.job;
  };
  const save = async job => etags.set(job, await store.update(job.id, job, etags.get(job)));

  async function submit(job, name, endpoint, body) {
    job.stage = name;
    job.progress = 0;
    job.submitting = name;
    job.submittingAt = now();
    await save(job);
    const result = await api.create(endpoint, body);
    if (typeof result.task_id !== 'string') throw new Error('Tripo did not return a task ID. Check the dashboard before retrying.');
    job.tasks[name] = result.task_id;
    job.submitting = null;
    job.stageStartedAt = now();
    job.failures = 0;
    return save(job);
  }

  async function finish(job, warning) {
    if (warning) job.warning = warning;
    job.status = 'ready';
    job.stage = 'ready';
    job.progress = 100;
    return save(job);
  }

  // Moves a working job forward by at most one Tripo stage.
  async function advance(job) {
    if (job.submitting) {
      if (now() - job.submittingAt < STALE_SUBMISSION) return;
      throw new Error('Submission was interrupted. Check Tripo before starting another paid generation.');
    }
    const name = job.stage;
    if (now() - job.stageStartedAt > STAGE_DEADLINE) throw new Error('Stopped waiting. The Tripo task may still complete; no duplicate task was submitted.');
    let result;
    try { result = await api.task(job.tasks[name]); job.failures = 0; }
    catch (error) {
      if (++job.failures >= 5) throw error;
      return save(job);
    }
    job.progress = Math.min(100, Math.max(0, Number(result.progress) || 0));
    if (ENDED.includes(result.status)) throw new Error(`Tripo ${name} ${result.status}. Check task ${job.tasks[name]} in the dashboard.`);
    if (result.status !== 'success') return save(job);
    job.results[name] = { credits: Number(result.credits_consumed) || 0 };

    if (name === 'generating') {
      await store.saveModel(job.id, 'mesh', await api.download(result.output?.model_url));
      // Hide-and-seek ghosts keep the pose from the photo, so they skip rigging (faster, fewer credits).
      if (job.rig === false) return finish(job);
      return submit(job, 'checking', 'animations/rig-check', { input: job.tasks.generating });
    }
    if (name === 'checking') {
      if (result.output?.riggable !== true || result.output?.rig_type !== 'biped') {
        return finish(job, 'Tripo could not confirm a humanoid rig. You can rotate the mesh, but not pose its joints. Try a standing full-body photo.');
      }
      return submit(job, 'rigging', 'animations/rig', {
        input: job.tasks.generating, model: 'v3.0-20260909', rig_type: 'biped', spec: 'mixamo', out_format: 'glb'
      });
    }
    await store.saveModel(job.id, 'rigged', await api.download(result.output?.model_url));
    job.rigged = true;
    return finish(job);
  }

  async function poll(id) {
    const job = await load(id);
    if (!job) fail(404, 'Character not found on this server.');
    if (job.status !== 'working') return job;
    try {
      await advance(job);
    } catch (error) {
      // Another request moved the job on first; report its version.
      if (error instanceof Conflict) return load(id);
      // Once the mesh exists, a rigging problem still leaves a usable character.
      if (job.stage === 'checking' || job.stage === 'rigging') {
        job.submitting = null;
        await finish(job, 'Mesh is ready, but rigging did not complete. ' + error.message).catch(() => {});
      } else {
        job.status = 'failed';
        job.error = error.message;
        await save(job).catch(() => {});
      }
    }
    return job;
  }

  async function create(req, id) {
    if (!apiKey) fail(503, 'Add TRIPO_API_KEY to the server environment and redeploy.');
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
    const replay = async () => {
      const job = await load(id);
      if (job.hash !== hash) fail(409, 'This request ID already belongs to another cutout.');
      return [200, job];
    };
    if (await store.read(id)) return replay();
    if (await store.countSince(now() - DAY) >= maxJobsPerDay) fail(429, 'Daily generation limit reached. Try again tomorrow.');

    const fileToken = await api.upload(data);
    const job = { id, hash, createdAt: now(), status: 'working', stage: 'generating', progress: 0,
      tasks: {}, results: {}, rig: req.headers['x-rig'] !== '0', failures: 0,
      submitting: 'generating', submittingAt: now() };
    try { etags.set(job, await store.create(id, job)); }
    catch (error) { if (error instanceof Conflict) return replay(); throw error; }
    await store.count(id, job.createdAt);
    try {
      const result = await api.create('generation/image-to-model', {
        input: fileToken, model: 'v3.1-20260211', face_limit: 20000,
        texture: true, pbr: true, texture_quality: 'standard', orientation: 'align_image'
      });
      if (typeof result.task_id !== 'string') throw new Error('Tripo did not return a task ID. Check the dashboard before retrying.');
      job.tasks.generating = result.task_id;
      job.submitting = null;
      job.stageStartedAt = now();
    } catch (error) {
      job.status = 'failed';
      job.error = error.message;
    }
    await save(job);
    return [202, job];
  }

  return async function handleCharacters(req, res, pathname) {
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    const send = (status, body) => { res.writeHead(status, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(body)); };
    try {
      if (req.headers.origin) fail(403, 'Browser requests are not allowed. Use the native app.');
      if (accessToken) {
        const supplied = createHash('sha256').update(req.headers.authorization ?? '').digest();
        const expected = createHash('sha256').update(`Bearer ${accessToken}`).digest();
        if (!timingSafeEqual(supplied, expected)) fail(401, 'Enter the 3D server access token, not your Tripo API key.');
      } else if (!['127.0.0.1', '::1', '::ffff:127.0.0.1'].includes(req.socket.remoteAddress)) {
        fail(403, 'Remote use requires TRIPO_PROXY_TOKEN on the server.');
      }
      if (req.method === 'POST' && pathname === '/characters') {
        const [status, job] = await create(req, req.headers['x-request-id']);
        return send(status, snapshot(job));
      }
      const match = pathname.match(/^\/characters\/([a-f0-9-]{36})(?:\/(model))?$/i);
      if (!match) fail(404, 'Character not found on this server.');
      if (req.method !== 'GET') fail(405, 'Unsupported method.');
      if (!match[2]) return send(200, snapshot(await poll(match[1])));
      const job = await load(match[1]);
      if (!job) fail(404, 'Character not found on this server.');
      if (job.status !== 'ready') fail(409, 'The model is not ready.');
      // Models can be far larger than a function response, so the app downloads from storage.
      res.writeHead(302, { Location: await store.modelURL(job.id, job.rigged ? 'rigged' : 'mesh') });
      res.end();
    } catch (error) {
      if (!error.status) console.error(error);
      if (!res.headersSent) send(error.status ?? 500, { error: error.status ? error.message : '3D server error. Check the server logs.' });
      else res.destroy();
    }
  };
}
