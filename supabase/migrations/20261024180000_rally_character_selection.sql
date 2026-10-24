-- Apply before deploying the character-aware lobby API. Existing rooms retain legacy rules.
-- Old API instances omit the new fields; updates preserve them during a rolling deployment.
begin;

alter table rally.rooms add column if not exists requires_character boolean not null default false;
alter table rally.members add column if not exists has_character boolean not null default false;

-- One round trip to lock and read a room, one to write a request's changes and commit.
-- Through Supavisor's transaction pooler prepared statements are off, so every parameterized
-- query costs an extra round trip; doing the work in these functions keeps a room locked for
-- about one round trip per request instead of eight.

-- Locks the room and returns it as JSON, or null when there is no such room.
-- Called inside the request's transaction; the lock is held until it commits.
create or replace function rally.room_load(p_code text) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_room uuid;
begin
  select id into v_room from rally.rooms where code = p_code for update;
  if not found then
    return null;
  end if;
  -- A separate statement, so it reads with a snapshot taken after the lock was granted.
  -- (Read in the locking statement, joined rows would predate the previous request's commit.)
  return (
    select jsonb_build_object(
      'id', r.id, 'code', r.code, 'locked', r.locked, 'status', r.status, 'requiresCharacter', r.requires_character,
      'createdAt', (extract(epoch from r.created_at) * 1000)::bigint,
      'touchedAt', (extract(epoch from r.touched_at) * 1000)::bigint,
      'game', g.state, 'surfaces', g.surfaces,
      'members', coalesce((
        select jsonb_agg(jsonb_build_object('id', m.id, 'name', m.name, 'avatar', m.avatar,
          'host', m.host, 'ready', m.ready, 'hasCharacter', m.has_character, 'tokenHash', m.token_hash,
          'seenAt', (extract(epoch from m.seen_at) * 1000)::bigint) order by m.seq)
        from rally.members m where m.room_id = r.id), '[]'::jsonb),
      'disguises', coalesce((
        select jsonb_agg(jsonb_build_object('id', d.member_id, 'version', d.version, 'boxes', d.boxes,
          'offset', d.placement_offset, 'blob', d.storage_path, 'size', d.size_bytes))
        from rally.disguises d join rally.members m on m.id = d.member_id
        where m.room_id = r.id), '[]'::jsonb))
    from rally.rooms r left join rally.games g on g.room_id = r.id
    where r.id = v_room);
end
$$;

-- Applies the changes one request made to a room it holds locked (see saveRoom in
-- server/lib/supabase-store.mjs for the shape). Times are milliseconds since the epoch.
create or replace function rally.room_save(p_room uuid, p_changes jsonb) returns void
language plpgsql
set search_path = ''
as $$
begin
  if coalesce((p_changes->>'closed')::boolean, false) then
    delete from rally.rooms where id = p_room;
    return;
  end if;

  if p_changes ? 'room' then
    update rally.rooms
    set locked = (p_changes->'room'->>'locked')::boolean,
        status = p_changes->'room'->>'status',
        requires_character = coalesce((p_changes->'room'->>'requiresCharacter')::boolean, requires_character),
        touched_at = to_timestamp((p_changes->'room'->>'touchedAt')::double precision / 1000)
    where id = p_room;
  end if;

  delete from rally.members
  where room_id = p_room
    and id in (select value::uuid from jsonb_array_elements_text(coalesce(p_changes->'removed', '[]')));

  insert into rally.members (id, room_id, name, name_key, avatar, host, ready, has_character, token_hash, joined_at, seen_at)
  select m.id, p_room, m.name, m."nameKey", m.avatar, m.host, m.ready, coalesce(m."hasCharacter", false), m."tokenHash",
    to_timestamp(m."seenAt" / 1000), to_timestamp(m."seenAt" / 1000)
  from jsonb_to_recordset(coalesce(p_changes->'added', '[]')) as m(id uuid, name text, "nameKey" text,
    avatar smallint, host boolean, ready boolean, "hasCharacter" boolean, "tokenHash" text, "seenAt" double precision);

  update rally.members t
  set ready = c.ready, has_character = coalesce(c."hasCharacter", t.has_character), seen_at = to_timestamp(c."seenAt" / 1000)
  from jsonb_to_recordset(coalesce(p_changes->'changed', '[]')) as c(id uuid, ready boolean, "hasCharacter" boolean, "seenAt" double precision)
  where t.id = c.id and t.room_id = p_room;

  if p_changes ? 'game' then
    if jsonb_typeof(p_changes->'game') = 'null' then
      delete from rally.games where room_id = p_room;
    elsif p_changes ? 'surfaces' then
      insert into rally.games (room_id, state, surfaces)
      values (p_room, p_changes->'game', p_changes->'surfaces')
      on conflict (room_id) do update
        set state = excluded.state, surfaces = excluded.surfaces, started_at = now(), updated_at = now();
    else
      update rally.games set state = p_changes->'game', updated_at = now() where room_id = p_room;
    end if;
  end if;

  insert into rally.disguises (member_id, version, boxes, placement_offset, storage_path, size_bytes)
  select d.id, d.version, d.boxes, d."offset", d.blob, d.size
  from jsonb_to_recordset(coalesce(p_changes->'disguises', '[]')) as d(id uuid, version text,
    boxes jsonb, "offset" jsonb, blob text, size integer)
  where exists (select 1 from rally.members m where m.id = d.id and m.room_id = p_room)
  on conflict (member_id) do update
    set version = excluded.version, boxes = excluded.boxes, placement_offset = excluded.placement_offset,
        storage_path = excluded.storage_path, size_bytes = excluded.size_bytes, updated_at = now();

  delete from rally.disguises d
  using rally.members m
  where m.id = d.member_id and m.room_id = p_room
    and d.member_id in (select value::uuid from jsonb_array_elements_text(coalesce(p_changes->'dropped', '[]')));
end
$$;


-- CREATE OR REPLACE preserves the existing function ownership and restricted grants.
commit;
