import { randomInt } from 'node:crypto';

const fail = (status, message) => { throw Object.assign(new Error(message), { status }); };
const unavailable = () => fail(503, 'Online AR rounds need the Supabase store (not RALLY_STORE=memory).');

// Rooms in this process's memory: for tests and a single local server on Wi-Fi.
// Nothing is shared between processes, so deployments use the Supabase store instead.
//
// Store contract (see supabase-store.mjs for the shared implementation):
//   withRoom(code, fn)   runs fn(room | null) atomically for that room and saves what it changed,
//                        including when fn throws an HTTP error; room.closed deletes the room.
//   createRoom(fn, opts) creates a room with a fresh six-digit code and runs fn(room) on it.
//   putDisguise / readDisguise / discardDisguise  keep GLB bytes; disguise.blob refers to them.
export function createMemoryRoomStore({ maxDisguiseBytes = 256 * 1024 * 1024 } = {}) {
  const rooms = new Map();
  return {
    async withRoom(code, fn) {
      const room = rooms.get(code) ?? null;
      try { return fn(room); }
      finally { if (room?.closed) rooms.delete(code); }
    },
    async createRoom(fn, { time, maxRooms, prune }) {
      for (const [code, room] of rooms) if (!prune(room, time)) rooms.delete(code);
      if (rooms.size >= maxRooms) fail(503, 'The server is full. Try again later.');
      let code;
      do { code = String(randomInt(100000, 1000000)); } while (rooms.has(code));
      const room = { code, locked: false, status: 'waiting', createdAt: new Date(time).toISOString(),
        touchedAt: time, game: null, ar: null, members: [], disguises: new Map() };
      const result = fn(room);
      rooms.set(code, room);
      return result;
    },
    async putDisguise(owner, data) {
      let stored = 0;
      for (const room of rooms.values()) for (const disguise of room.disguises.values()) stored += disguise.blob.length;
      if (stored + data.length > maxDisguiseBytes) fail(503, 'The development server has reached its disguise memory limit.');
      return data;
    },
    async readDisguise(blob) { return blob; },
    // AR rounds move large files through Supabase Storage, which a single local process doesn't have.
    async exist() { throw unavailable(); },
    async signUpload() { throw unavailable(); },
    async signDownload() { throw unavailable(); },
    async discardDisguise() {}
  };
}
