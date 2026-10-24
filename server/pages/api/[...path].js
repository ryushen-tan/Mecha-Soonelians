import { createLobbyHandler } from '../../lib/lobby.mjs';
import { createCharactersHandler } from '../../lib/characters.mjs';
import { createBlobStore } from '../../lib/blob-store.mjs';

// Keep one room store across requests and development route recompilation.
// Run one persistent Next.js process; serverless replicas need shared storage.
const key = Symbol.for('rally.lobby');
const handler = globalThis[key] ??= createLobbyHandler();

// 3D characters keep their state in Vercel Blob, so any instance can serve them.
let characters;

// Saving a large generated model to storage can take a while.
export const config = { api: { bodyParser: false, responseLimit: '20mb' }, maxDuration: 300 };

export default function lobby(req, res) {
  const path = `/${req.query.path.join('/')}`;
  if (path === '/characters' || path.startsWith('/characters/')) {
    characters ??= createCharactersHandler({ store: createBlobStore() });
    return characters(req, res, path);
  }
  return handler(req, res, path);
}
