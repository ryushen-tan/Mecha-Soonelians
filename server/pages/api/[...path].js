import { createLobbyHandler } from '../../lib/lobby.mjs';
import { createRoomStoreFromEnv } from '../../lib/supabase-store.mjs';
import { createCharactersHandler } from '../../lib/characters.mjs';
import { createBlobStore } from '../../lib/blob-store.mjs';

// Rooms live in Supabase, so every serverless instance sees the same rooms. Keep one handler
// (and its database pool) across requests and development route recompilation.
const key = Symbol.for('rally.lobby');
const handler = globalThis[key] ??= createLobbyHandler({ store: createRoomStoreFromEnv() });

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
