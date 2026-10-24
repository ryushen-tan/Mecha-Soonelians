import http from 'node:http';
import { randomUUID } from 'node:crypto';
import { DISGUISE_BUCKET } from '../lib/supabase-store.mjs';

// The Supabase Storage endpoints supabase-js uses for upload, download and remove.
export async function startStorage({ key }) {
  const objects = new Map();
  const prefix = `/storage/v1/object/${DISGUISE_BUCKET}`;
  const server = http.createServer(async (req, res) => {
    const reply = (status, body) => { res.writeHead(status, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(body)); };
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    const body = Buffer.concat(chunks);
    if (req.headers.apikey !== key) return reply(403, { statusCode: '403', error: 'Unauthorized', message: 'Invalid API key' });
    const { pathname } = new URL(req.url, 'http://storage');
    if (req.method === 'DELETE' && pathname === prefix) {
      const removed = JSON.parse(body).prefixes.filter(path => objects.delete(path));
      return reply(200, removed.map(name => ({ name, bucket_id: DISGUISE_BUCKET })));
    }
    if (!pathname.startsWith(`${prefix}/`)) return reply(404, { statusCode: '404', error: 'Bucket not found', message: 'Bucket not found' });
    const path = decodeURIComponent(pathname.slice(prefix.length + 1));
    if (req.method === 'POST') {
      if (objects.has(path) && req.headers['x-upsert'] !== 'true') return reply(409, { statusCode: '409', error: 'Duplicate', message: 'The resource already exists' });
      objects.set(path, { data: body, type: req.headers['content-type'] });
      return reply(200, { Key: `${DISGUISE_BUCKET}/${path}`, Id: randomUUID() });
    }
    if (req.method === 'GET') {
      const object = objects.get(path);
      if (!object) return reply(404, { statusCode: '404', error: 'not_found', message: 'Object not found' });
      res.writeHead(200, { 'Content-Type': object.type });
      return res.end(object.data);
    }
    reply(405, { statusCode: '405', error: 'Method not allowed', message: 'Method not allowed' });
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  return {
    objects,
    url: `http://127.0.0.1:${server.address().port}`,
    close: () => new Promise(resolve => { server.close(resolve); server.closeAllConnections(); })
  };
}
