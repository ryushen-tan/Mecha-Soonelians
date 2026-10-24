// Tripo API client and input checks, shared by the local 3D server (tripo.mjs)
// and the hosted Next.js route (lib/characters.mjs).
const fail = (status, message) => { throw Object.assign(new Error(message), { status }); };
const MAX_IMAGE = 5 * 1024 * 1024;
const MAX_MODEL = 100 * 1024 * 1024;

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
