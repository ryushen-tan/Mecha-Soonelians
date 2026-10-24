-- One round trip to lock and read a room, one to write a request's changes and commit.
-- Through Supavisor's transaction pooler prepared statements are off, so every parameterized
-- query costs an extra round trip; doing the work in these functions keeps a room locked for
-- about one round trip per request instead of eight.

-- Locks the room and returns it as JSON, or null when there is no such room.
-- Called inside the request's transaction; the lock is held until it commits.
create function rally.room_load(p_code text) returns jsonb
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
      'id', r.id, 'code', r.code, 'locked', r.locked, 'status', r.status,
      'createdAt', (extract(epoch from r.created_at) * 1000)::bigint,
      'touchedAt', (extract(epoch from r.touched_at) * 1000)::bigint,
      'game', g.state, 'surfaces', g.surfaces,
      'members', coalesce((
        select jsonb_agg(jsonb_build_object('id', m.id, 'name', m.name, 'avatar', m.avatar,
          'host', m.host, 'ready', m.ready, 'tokenHash', m.token_hash,
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
create function rally.room_save(p_room uuid, p_changes jsonb) returns void
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
        touched_at = to_timestamp((p_changes->'room'->>'touchedAt')::double precision / 1000)
    where id = p_room;
  end if;

  delete from rally.members
  where room_id = p_room
    and id in (select value::uuid from jsonb_array_elements_text(coalesce(p_changes->'removed', '[]')));

  insert into rally.members (id, room_id, name, name_key, avatar, host, ready, token_hash, joined_at, seen_at)
  select m.id, p_room, m.name, m."nameKey", m.avatar, m.host, m.ready, m."tokenHash",
    to_timestamp(m."seenAt" / 1000), to_timestamp(m."seenAt" / 1000)
  from jsonb_to_recordset(coalesce(p_changes->'added', '[]')) as m(id uuid, name text, "nameKey" text,
    avatar smallint, host boolean, ready boolean, "tokenHash" text, "seenAt" double precision);

  update rally.members t
  set ready = c.ready, seen_at = to_timestamp(c."seenAt" / 1000)
  from jsonb_to_recordset(coalesce(p_changes->'changed', '[]')) as c(id uuid, ready boolean, "seenAt" double precision)
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

-- Creates an empty room with the first unused code among p_codes (random, from the API), after
-- closing expired rooms. Returns {id, code}, or null when the server is full.
create function rally.room_create(p_now bigint, p_member_ttl bigint, p_idle_ttl bigint,
  p_max_rooms integer, p_codes text[]) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_now timestamptz := to_timestamp(p_now / 1000.0);
  v_code text;
  v_room rally.rooms;
begin
  -- One creation at a time keeps the room cap exact across instances.
  perform pg_advisory_xact_lock(hashtext('rally.room_create'));
  perform rally.cleanup_expired(v_now, p_member_ttl * interval '1 millisecond', p_idle_ttl * interval '1 millisecond');
  if (select count(*) from rally.rooms) >= p_max_rooms then
    return null;
  end if;
  foreach v_code in array p_codes loop
    insert into rally.rooms (code, created_at, touched_at) values (v_code, v_now, v_now)
    on conflict (code) do nothing
    returning * into v_room;
    if found then
      return jsonb_build_object('id', v_room.id, 'code', v_room.code);
    end if;
  end loop;
  return null;
end
$$;

revoke all on function rally.room_create(bigint, bigint, bigint, integer, text[]) from public, anon, authenticated, service_role;
grant execute on function rally.room_create(bigint, bigint, bigint, integer, text[]) to rally_api;
revoke all on function rally.room_load(text) from public, anon, authenticated, service_role;
revoke all on function rally.room_save(uuid, jsonb) from public, anon, authenticated, service_role;
grant execute on function rally.room_load(text) to rally_api;
grant execute on function rally.room_save(uuid, jsonb) to rally_api;
