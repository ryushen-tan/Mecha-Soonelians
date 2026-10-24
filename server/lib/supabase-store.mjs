import { randomBytes, randomInt, randomUUID } from 'node:crypto';
import postgres from 'postgres';
import { createClient } from '@supabase/supabase-js';
import { createMemoryRoomStore } from './room-store.mjs';

// Rooms in Supabase: Postgres (schema rally, see supabase/migrations) is the source of truth,
// and disguise GLBs live in the private rally-disguises Storage bucket.
//
// Each request runs in one transaction that locks the room row (SELECT ... FOR UPDATE), loads
// the room, runs the lobby's synchronous logic on it and writes back only what changed. Every
// API instance therefore applies changes to a room one at a time, like the old single process.

export const DISGUISE_BUCKET = 'rally-disguises';
const fail = (status, message) => { throw Object.assign(new Error(message), { status }); };

// Infrastructure failures become a retryable 503, never a 404 or 401 that would make the app
// discard its membership.
const unavailable = cause => Object.assign(
  new Error('The game server is temporarily unavailable. Try again in a moment.'),
  { status: 503, retryAfter: 2, cause });

export function createRoomStoreFromEnv(env = process.env) {
  if (env.RALLY_STORE === 'memory') return createMemoryRoomStore();
  const databaseURL = env.RALLY_DATABASE_URL;
  const supabaseURL = env.SUPABASE_URL;
  const secretKey = env.SUPABASE_SECRET_KEY || env.SUPABASE_SERVICE_ROLE_KEY;
  const missing = [!databaseURL && 'RALLY_DATABASE_URL', !supabaseURL && 'SUPABASE_URL', !secretKey && 'SUPABASE_SECRET_KEY'].filter(Boolean);
  if (missing.length) {
    // Refuse rather than fall back to memory: per-instance rooms are what broke multiplayer.
    const problem = new Error(`Room storage is not configured. Set ${missing.join(', ')} (or RALLY_STORE=memory for one local process).`);
    const refuse = async () => { throw unavailable(problem); };
    return { withRoom: refuse, createRoom: refuse, putDisguise: refuse, readDisguise: refuse, discardDisguise: async () => {} };
  }
  const local = ['localhost', '127.0.0.1', '[::1]'].includes(new URL(databaseURL).hostname);
  const sql = postgres(databaseURL, {
    prepare: false, // Required by Supavisor's transaction pooler.
    max: 5, idle_timeout: 20, connect_timeout: 5, onnotice: () => {},
    ssl: env.RALLY_DATABASE_CA_CERT ? { ca: env.RALLY_DATABASE_CA_CERT } : local ? false : 'require'
  });
  const storage = createClient(supabaseURL, secretKey, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false }
  }).storage.from(DISGUISE_BUCKET);
  return createSupabaseRoomStore({ sql, storage });
}

export function createSupabaseRoomStore({ sql, storage }) {
  const logicErrors = new WeakSet();

  async function guard(work) {
    try { return await work(); }
    catch (error) { throw error.status || logicErrors.has(error) ? error : unavailable(error); }
  }

  // Simple-protocol queries skip the describe round trip that every parameterized query costs
  // through the pooler, and several statements share one round trip. Values are inlined only
  // after validation (codes, UUIDs, integers) or inside a dollar-quoted literal whose random tag
  // does not occur in the text, so nothing in a value can end the literal.
  const CODE = /^[0-9]{6}$/;
  const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
  const integer = value => { if (!Number.isSafeInteger(value)) throw new Error(`Not an integer: ${value}`); return String(value); };
  const uuid = value => { if (!UUID.test(value)) throw new Error('Not a UUID'); return `'${value}'`; };
  const quoted = text => {
    let tag;
    do tag = `$r${randomBytes(8).toString('hex')}$`; while (text.includes(tag));
    return tag + text + tag;
  };
  const column = (result, name) => [result].flat(2).find(row => row && name in row)?.[name];

  const hydrate = data => ({
    id: data.id, code: data.code, locked: data.locked, status: data.status, requiresCharacter: data.requiresCharacter ?? false,
    createdAt: new Date(data.createdAt).toISOString(), touchedAt: data.touchedAt,
    game: data.game && { ...data.game, surfaces: data.surfaces },
    members: data.members.map(member => ({ ...member, stored: true })),
    disguises: new Map(data.disguises.map(({ id, offset, ...disguise }) => [id, offset ? { ...disguise, offset } : disguise]))
  });

  // Surfaces are written only when a round starts; the rest of the game changes on most polls.
  const gameState = game => game ? JSON.stringify({ ...game, surfaces: undefined }) : null;

  const capture = room => ({
    locked: room.locked, status: room.status, touchedAt: room.touchedAt, requiresCharacter: room.requiresCharacter,
    members: new Map(room.members.map(m => [m.id, { ready: m.ready, hasCharacter: m.hasCharacter, seenAt: m.seenAt }])),
    game: gameState(room.game), surfaces: room.game?.surfaces,
    disguises: new Map([...room.disguises].map(([id, disguise]) => [id, JSON.stringify(disguise)]))
  });

  // The differences between the loaded room and the room after the request, in the shape
  // rally.room_save applies. orphaned is true when Storage files may have lost their rows.
  function changes(room, before) {
    if (room.closed) return { payload: { closed: true }, orphaned: true };
    const payload = {};
    let orphaned = false;
    if (room.locked !== before.locked || room.status !== before.status || room.touchedAt !== before.touchedAt || room.requiresCharacter !== before.requiresCharacter) {
      payload.room = { locked: room.locked, status: room.status, touchedAt: room.touchedAt, requiresCharacter: room.requiresCharacter };
    }
    const kept = new Set(room.members.map(m => m.id));
    const removed = [...before.members.keys()].filter(id => !kept.has(id));
    if (removed.length) { payload.removed = removed; orphaned = true; }
    const added = room.members.filter(m => !m.stored).map(({ id, name, nameKey, avatar, host, ready, hasCharacter, tokenHash, seenAt }) =>
      ({ id, name, nameKey, avatar, host, ready, hasCharacter, tokenHash, seenAt }));
    if (added.length) payload.added = added;
    const changed = room.members.filter(m => m.stored &&
      (before.members.get(m.id).ready !== m.ready || before.members.get(m.id).seenAt !== m.seenAt || before.members.get(m.id).hasCharacter !== m.hasCharacter))
      .map(({ id, ready, hasCharacter, seenAt }) => ({ id, ready, hasCharacter, seenAt }));
    if (changed.length) payload.changed = changed;
    const game = gameState(room.game);
    if (!game && before.game) payload.game = null;
    else if (game && (!before.game || room.game.surfaces !== before.surfaces)) {
      payload.game = { ...room.game, surfaces: undefined };
      payload.surfaces = room.game.surfaces;
    } else if (game && game !== before.game) payload.game = { ...room.game, surfaces: undefined };
    const disguises = [];
    for (const [id, disguise] of room.disguises) {
      const previous = before.disguises.get(id);
      if (!kept.has(id) || JSON.stringify(disguise) === previous) continue;
      if (previous && JSON.parse(previous).blob !== disguise.blob) orphaned = true;
      const { version, boxes, offset = null, blob, size } = disguise;
      disguises.push({ id, version, boxes, offset, blob, size });
    }
    if (disguises.length) payload.disguises = disguises;
    const dropped = [...before.disguises.keys()].filter(id => kept.has(id) && !room.disguises.has(id));
    if (dropped.length) { payload.dropped = dropped; orphaned = true; }
    return { payload, orphaned };
  }

  // Runs one request's transaction: begin | <open> locks and reads | <save> | commit.
  // The room stays locked for about two round trips. Every statement is a simple-protocol query,
  // so none pays the pooler's extra describe round trip.
  // work returns { value, error, save, orphaned }. An HTTP error returned this way is reported
  // after its changes commit; anything work throws rolls the transaction back.
  // (Not sql.reserve: a reserved connection that drops goes back to the pool as if open, and
  // later requests hang on it. Not a commit inside sql.begin: once idle, its connection returns
  // to the pool before sql.begin's own commit is sent.)
  async function transaction(open, work) {
    let step;
    await guard(async () => {
      try {
        await sql.begin(async tx => {
          const opened = await tx.unsafe(open);
          try { step = work(opened); }
          catch (error) { if (!error.status) logicErrors.add(error); throw error; }
          if (step.save) await tx.unsafe(step.save);
        });
      } catch (error) {
        // The lobby checks names under the same lock, so this is only a backstop.
        if (error.code === '23505' && error.constraint_name === 'members_room_name_key') fail(409, 'That name is taken in this room. Try another.');
        throw error;
      }
    });
    if (step.orphaned) await emptyTrash();
    if (step.error) throw step.error;
    return step.value;
  }

  const saveRoom = (room, before) => {
    const { payload, orphaned } = changes(room, before);
    return { save: `select rally.room_save(${uuid(room.id)}, ${quoted(JSON.stringify(payload))}::jsonb)`, orphaned };
  };

  // Deletes Storage files whose rows are gone (queued by a trigger, including rows removed by
  // the scheduled cleanup). Failures leave them queued for the next attempt.
  async function emptyTrash() {
    try {
      await sql.begin(async tx => {
        const rows = await tx`select path from rally.storage_trash order by queued_at limit 100 for update skip locked`;
        if (!rows.length) return;
        const paths = rows.map(row => row.path);
        const { error } = await storage.remove(paths);
        if (error) throw error;
        await tx`delete from rally.storage_trash where path = any(${tx.array(paths)}::text[])`;
      });
    } catch (error) {
      console.error('Could not delete stale disguise files; they stay queued.', error);
    }
  }

  return {
    async withRoom(code, fn) {
      if (!CODE.test(code)) return fn(null);
      return transaction(`select rally.room_load('${code}') as room`, opened => {
        const data = column(opened, 'room');
        const room = data ? hydrate(data) : null;
        const before = room && capture(room);
        let value, error;
        try { value = fn(room); }
        catch (thrown) { if (!thrown.status) throw thrown; error = thrown; }
        return { value, error, ...(room && saveRoom(room, before)) };
      });
    },

    async createRoom(fn, { time, maxRooms, memberTTL, idleTTL }) {
      // Codes come from the crypto RNG; rally.room_create takes the first one not in use.
      const candidates = Array.from({ length: 20 }, () => `'${randomInt(100000, 1000000)}'`).join(', ');
      const value = await transaction(`select rally.room_create(${integer(time)}, ${integer(memberTTL)},
        ${integer(idleTTL)}, ${integer(maxRooms)}, array[${candidates}]) as room`, opened => {
        const created = column(opened, 'room');
        if (!created) fail(503, 'The server is full. Try again later.');
        const room = { id: created.id, code: created.code, locked: false, status: 'waiting',
          createdAt: new Date(time).toISOString(), touchedAt: time, game: null, members: [], disguises: new Map() };
        const before = capture(room);
        return { value: fn(room), ...saveRoom(room, before) };
      });
      await emptyTrash(); // Files of rooms the cleanup just closed.
      return value;
    },

    async putDisguise({ roomID, memberID }, data) {
      const path = `${roomID}/${memberID}/${randomUUID()}.glb`;
      const { error } = await storage.upload(path, data, { contentType: 'model/gltf-binary', upsert: false });
      if (error) throw unavailable(error);
      return path;
    },

    async readDisguise(path) {
      const { data, error } = await storage.download(path);
      if (error) throw unavailable(error);
      return Buffer.from(await data.arrayBuffer());
    },

    // An upload that was not published. Queue it unless a row uses it (a commit whose reply was lost).
    async discardDisguise(path) {
      try {
        await sql`insert into rally.storage_trash (path)
          select ${path} where not exists (select 1 from rally.disguises where storage_path = ${path})
          on conflict do nothing`;
      } catch (error) {
        console.error(`Could not queue unpublished disguise ${path} for deletion.`, error);
        return;
      }
      await emptyTrash();
    }
  };
}
