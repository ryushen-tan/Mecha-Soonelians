import http from 'node:http';
import { createLobbyHandler } from '../lib/lobby.mjs';
import { createRoomStoreFromEnv } from '../lib/supabase-store.mjs';

// One API process, configured like the Vercel function. Tests start several of these.
const option = name => process.env[name] ? Number(process.env[name]) : undefined;
const handler = createLobbyHandler({ store: createRoomStoreFromEnv(),
  memberTTL: option('RALLY_MEMBER_TTL_MS'), rateLimit: option('RALLY_RATE_LIMIT') });
const server = http.createServer((req, res) => handler(req, res));
server.listen(0, '127.0.0.1', () => process.send({ port: server.address().port }));
