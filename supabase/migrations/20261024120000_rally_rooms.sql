-- Rally rooms: the authoritative, shared room state for the lobby API.
--
-- The API (server/lib/supabase-store.mjs) connects as rally_api through the Supavisor
-- pooler and locks a room row (SELECT ... FOR UPDATE) for the whole of each request,
-- so concurrent serverless instances apply changes to a room one at a time.
-- Nothing here is reachable by Supabase client keys: the schema is not exposed to the
-- Data API, RLS is enabled with policies only for rally_api, and anon, authenticated
-- and service_role hold no privileges.

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'rally_api') then
    -- Login is enabled during setup with: alter role rally_api with login password '...';
    create role rally_api nologin noinherit;
  end if;
end
$$;

-- Fail fast instead of queueing behind a stuck request; the API reports these as 503.
alter role rally_api set statement_timeout = '5s';
alter role rally_api set lock_timeout = '4s';
alter role rally_api set idle_in_transaction_session_timeout = '15s';

create schema if not exists rally;

create table rally.rooms (
  id uuid primary key default gen_random_uuid(),
  code text not null constraint rooms_code_key unique
    constraint rooms_code_format check (code ~ '^[0-9]{6}$'),
  locked boolean not null default false,
  status text not null default 'waiting' constraint rooms_status check (status in ('waiting', 'started')),
  created_at timestamptz not null default now(),
  -- Last authenticated request or join; the room closes after two idle hours.
  touched_at timestamptz not null default now()
) with (fillfactor = 80);

create table rally.members (
  id uuid primary key,
  room_id uuid not null references rally.rooms (id) on delete cascade,
  -- Join order; the API returns members in this order.
  seq bigint generated always as identity,
  name text not null constraint members_name_length check (char_length(name) between 1 and 20),
  -- name.toLocaleLowerCase('en-US'), computed by the API so the index matches its check exactly.
  name_key text not null,
  avatar smallint not null constraint members_avatar check (avatar between 0 and 5),
  host boolean not null default false,
  ready boolean not null default false,
  -- SHA-256 of the bearer token. The token itself is only ever sent to its owner.
  token_hash text not null constraint members_token_hash_key unique
    constraint members_token_hash_format check (token_hash ~ '^[0-9a-f]{64}$'),
  joined_at timestamptz not null default now(),
  -- Heartbeat; a member expires 90 seconds after their last request.
  seen_at timestamptz not null default now(),
  constraint members_room_name_key unique (room_id, name_key)
) with (fillfactor = 80);

create unique index members_one_host on rally.members (room_id) where host;

-- One row per running or finished round. The scanned room surfaces are kept apart from the
-- per-request state so polls do not rewrite up to 256 KB of geometry.
create table rally.games (
  room_id uuid primary key references rally.rooms (id) on delete cascade,
  state jsonb not null,
  surfaces jsonb not null,
  started_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
) with (fillfactor = 80);

-- Published disguise metadata. The GLB itself is in the private rally-disguises bucket.
create table rally.disguises (
  member_id uuid primary key references rally.members (id) on delete cascade,
  -- SHA-256 of the GLB, re-derived after an emergency eject moves it.
  version text not null constraint disguises_version_format check (version ~ '^[0-9a-f]{64}$'),
  boxes jsonb not null,
  placement_offset jsonb,
  storage_path text not null constraint disguises_storage_path_key unique,
  size_bytes integer not null constraint disguises_size check (size_bytes between 20 and 20971520),
  updated_at timestamptz not null default now()
);

-- Storage objects whose metadata row is gone. The API removes them through the Storage API,
-- since SQL cannot delete Storage files.
create table rally.storage_trash (
  path text primary key,
  queued_at timestamptz not null default now()
);

create function rally.trash_disguise_file() returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' or new.storage_path is distinct from old.storage_path then
    insert into rally.storage_trash (path) values (old.storage_path) on conflict do nothing;
  end if;
  return null;
end
$$;

create trigger disguises_trash_file
  after delete or update of storage_path on rally.disguises
  for each row execute function rally.trash_disguise_file();

-- Row level security: enabled everywhere, with policies only for the API role.
alter table rally.rooms enable row level security;
alter table rally.members enable row level security;
alter table rally.games enable row level security;
alter table rally.disguises enable row level security;
alter table rally.storage_trash enable row level security;

create policy rally_api_all on rally.rooms for all to rally_api using (true) with check (true);
create policy rally_api_all on rally.members for all to rally_api using (true) with check (true);
create policy rally_api_all on rally.games for all to rally_api using (true) with check (true);
create policy rally_api_all on rally.disguises for all to rally_api using (true) with check (true);
create policy rally_api_all on rally.storage_trash for all to rally_api using (true) with check (true);

-- Privileges: client roles get nothing, even if default privileges granted them access.
revoke all on schema rally from public, anon, authenticated, service_role;
revoke all on all tables in schema rally from public, anon, authenticated, service_role;
revoke all on all sequences in schema rally from public, anon, authenticated, service_role;
revoke all on all functions in schema rally from public, anon, authenticated, service_role;
alter default privileges in schema rally revoke all on tables from public, anon, authenticated, service_role;
alter default privileges in schema rally revoke all on sequences from public, anon, authenticated, service_role;
alter default privileges in schema rally revoke execute on functions from public, anon, authenticated, service_role;

grant usage on schema rally to rally_api;
grant select, insert, update, delete on rally.rooms, rally.members, rally.games, rally.disguises to rally_api;
-- UPDATE is needed for SELECT ... FOR UPDATE SKIP LOCKED while files are deleted.
grant select, insert, update, delete on rally.storage_trash to rally_api;
