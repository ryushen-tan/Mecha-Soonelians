import { BlobPreconditionFailedError, del, get, issueSignedToken, list, presignUrl, put } from '@vercel/blob';
import { Conflict } from './characters.mjs';

// Character jobs and models in a private Vercel Blob store. Job writes are
// conditional on the ETag that was read, so concurrent requests cannot clobber each other.
const access = 'private';
const jobPath = id => `tripo/jobs/${id}.json`;
const modelPath = (id, kind) => `tripo/models/${id}/${kind}.glb`;
const COUNTED = 'tripo/created/';

export function createBlobStore() {
  const read = async id => {
    const result = await get(jobPath(id), { access, useCache: false });
    if (!result || result.statusCode !== 200) return null;
    return { job: await new Response(result.stream).json(), etag: result.blob.etag };
  };
  const write = (id, job, options) => put(jobPath(id), JSON.stringify(job), {
    access, contentType: 'application/json', cacheControlMaxAge: 60, ...options
  });

  return {
    read,
    async create(id, job) {
      try { return (await write(id, job, { allowOverwrite: false })).etag; }
      catch (error) { if (await read(id)) throw new Conflict(); throw error; }
    },
    async update(id, job, etag) {
      try { return (await write(id, job, { ifMatch: etag })).etag; }
      catch (error) { if (error instanceof BlobPreconditionFailedError) throw new Conflict(); throw error; }
    },
    async saveModel(id, kind, data) {
      await put(modelPath(id, kind), data, {
        access, allowOverwrite: true, contentType: 'model/gltf-binary', multipart: data.length > 16 * 1024 * 1024
      });
    },
    async modelURL(id, kind) {
      const pathname = modelPath(id, kind);
      const token = await issueSignedToken({ pathname, operations: ['get'], validUntil: Date.now() + 15 * 60_000 });
      return (await presignUrl(token, { operation: 'get', pathname, access })).presignedUrl;
    },
    // One empty marker per generation, named by creation time, backs the daily limit.
    async count(id, createdAt) {
      await put(`${COUNTED}${createdAt}-${id}`, '', { access, contentType: 'text/plain' });
    },
    async countSince(time) {
      const recent = [];
      const expired = [];
      let cursor;
      do {
        const page = await list({ prefix: COUNTED, cursor, limit: 1000 });
        for (const blob of page.blobs) {
          (Number(blob.pathname.slice(COUNTED.length).split('-')[0]) >= time ? recent : expired).push(blob.url);
        }
        cursor = page.hasMore ? page.cursor : undefined;
      } while (cursor);
      if (expired.length) await del(expired).catch(() => {});
      return recent.length;
    }
  };
}
