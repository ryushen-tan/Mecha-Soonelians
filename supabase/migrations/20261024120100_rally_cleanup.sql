-- Scheduled expiry. Requests apply the same rules to the room they lock, so expiry holds
-- even when this job has not run yet; the job just removes rooms nobody asks about.
--   * A guest who has not made a request for 90 seconds leaves the room.
--   * A room closes when its host has not made a request for 90 seconds, or after two idle hours.

create function rally.cleanup_expired(
  p_now timestamptz default now(),
  p_member_ttl interval default interval '90 seconds',
  p_idle_ttl interval default interval '2 hours'
) returns integer
language plpgsql
set search_path = ''
as $$
declare
  closed integer;
begin
  -- Rooms an API request holds right now are skipped; that request applies the rules itself.
  with expired as (
    select r.id
    from rally.rooms r
    where r.touched_at < p_now - p_idle_ttl
       or not exists (
         select 1 from rally.members h
         where h.room_id = r.id and h.host and h.seen_at >= p_now - p_member_ttl)
    for update of r skip locked
  )
  delete from rally.rooms r using expired e where r.id = e.id;
  get diagnostics closed = row_count;

  with stale as (
    select r.id
    from rally.rooms r
    where exists (
      select 1 from rally.members m
      where m.room_id = r.id and not m.host and m.seen_at < p_now - p_member_ttl)
    for update of r skip locked
  )
  delete from rally.members m using stale s
  where m.room_id = s.id and not m.host and m.seen_at < p_now - p_member_ttl;

  return closed;
end
$$;

revoke all on function rally.cleanup_expired(timestamptz, interval, interval) from public, anon, authenticated, service_role;
grant execute on function rally.cleanup_expired(timestamptz, interval, interval) to rally_api;

-- Run every minute where pg_cron is available (it is on Supabase). Rescheduling by name is idempotent.
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron with schema pg_catalog;
    perform cron.schedule('rally-cleanup-expired', '* * * * *', 'select rally.cleanup_expired()');
  else
    raise notice 'pg_cron is unavailable; expired rooms are removed only when requested.';
  end if;
end
$$;
