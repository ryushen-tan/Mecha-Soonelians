import { createLobbyHandler } from '../../lib/lobby.mjs';

// Keep one room store across requests and development route recompilation.
// Run one persistent Next.js process; serverless replicas need shared storage.
const key = Symbol.for('rally.lobby');
const handler = globalThis[key] ??= createLobbyHandler();

export const config = { api: { bodyParser: false, responseLimit: '20mb' } };

export default function lobby(req, res) {
  return handler(req, res, `/${req.query.path.join('/')}`);
}
