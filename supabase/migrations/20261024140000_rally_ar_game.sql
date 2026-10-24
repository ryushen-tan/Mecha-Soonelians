-- The online AR hide-and-seek round: its state, and a private bucket for the scanned house and
-- the hiders' ghosts. Big files go straight between the phones and Storage on short-lived signed
-- URLs, because Vercel functions cannot carry a request or response over 4.5 MB.

create table rally.ar_games (
  room_id uuid primary key references rally.rooms (id) on delete cascade,
  -- Phase, timers, roles, readiness and ghosts (see server/lib/ar.mjs).
  state jsonb not null,
  started_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
) with (fillfactor = 80);

alter table rally.ar_games enable row level security;
create policy rally_api_all on rally.ar_games for all to rally_api using (true) with check (true);
revoke all on rally.ar_games from public, anon, authenticated, service_role;
grant select, insert, update, delete on rally.ar_games to rally_api;

-- Storage files to delete, now from more than one bucket. A path ending in '/' means
-- everything under that prefix.
alter table rally.storage_trash add column bucket text not null default 'rally-disguises';
alter table rally.storage_trash drop constraint storage_trash_pkey;
alter table rally.storage_trash add primary key (bucket, path);

-- A round's files live under <room id>/. They go when the room does, and a round's ghosts go
-- when the round is cleared for the next one.
create function rally.trash_ar_files() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_table_name = 'rooms' then
    insert into rally.storage_trash (bucket, path) values ('rally-ar', old.id::text || '/') on conflict do nothing;
  else
    insert into rally.storage_trash (bucket, path) values ('rally-ar', old.room_id::text || '/ghosts/') on conflict do nothing;
  end if;
  return null;
end
$$;

create trigger rooms_trash_ar_files after delete on rally.rooms
  for each row execute function rally.trash_ar_files();
create trigger ar_games_trash_ghosts after delete on rally.ar_games
  for each row execute function rally.trash_ar_files();

revoke all on function rally.trash_ar_files() from public, anon, authenticated, service_role;

insert into storage.buckets (id, name, public, file_size_limit)
values ('rally-ar', 'rally-ar', false, 157286400)
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit;

-- room_load / room_save carry the round with the room.
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
  return (
    select jsonb_build_object(
      'id', r.id, 'code', r.code, 'locked', r.locked, 'status', r.status,
      'createdAt', (extract(epoch from r.created_at) * 1000)::bigint,
      'touchedAt', (extract(epoch from r.touched_at) * 1000)::bigint,
      'game', g.state, 'surfaces', g.surfaces, 'ar', a.state,
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
    from rally.rooms r
      left join rally.games g on g.room_id = r.id
      left join rally.ar_games a on a.room_id = r.id
    where r.id = v_room);
end
$$;

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

  if p_changes ? 'ar' then
    if jsonb_typeof(p_changes->'ar') = 'null' then
      delete from rally.ar_games where room_id = p_room;
    else
      insert into rally.ar_games (room_id, state) values (p_room, p_changes->'ar')
      on conflict (room_id) do update set state = excluded.state, updated_at = now();
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

-- Redefining a function resets its grants; room_load / room_save stay API-only.
revoke all on function rally.room_load(text) from public, anon, authenticated, service_role;
revoke all on function rally.room_save(uuid, jsonb) from public, anon, authenticated, service_role;
grant execute on function rally.room_load(text) to rally_api;
grant execute on function rally.room_save(uuid, jsonb) to rally_api;
