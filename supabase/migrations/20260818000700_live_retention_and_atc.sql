-- Keeping the live table small, and letting it carry the ATC exchange.
--
-- Two things, and they belong together because the second is the thing most
-- likely to have broken the first.
--
-- WHAT GROWS AND WHAT DOES NOT. `pilot_live_status` is one row per pilot,
-- keyed on the account, written by upsert. It cannot grow past the number of
-- people who have ever flown with Connect attached, whatever anybody does — so
-- there is no volume problem to solve. There are two REAL problems, and neither
-- is row count:
--
--   1. Dead tuples. Postgres does not overwrite a row, it writes a new version
--      and leaves the old one for vacuum. A pilot on a fourteen-hour flight
--      updating every 45 seconds makes about 1,100 dead versions of one row.
--      Multiply by everybody flying and the table is mostly corpses.
--   2. Stale rows. Nothing reads them -- every read function already ignores
--      anything past the TTL -- but a table of live positions that only ever
--      accumulates is a table of historical positions, which is not what
--      anybody agreed to.
--
-- The fix for (1) is HOT updates: if no indexed column changes, Postgres can
-- put the new version on the same page and reclaim the old one without waiting
-- for vacuum. That requires two things, and the migration that created this
-- table got one of them wrong.

-- MARK: - Making the updates HOT
--
-- `pilot_live_status_fresh_idx` indexed `updated_at`, which changes on EVERY
-- write. That single index is what stopped every update being HOT: an indexed
-- column changing forces a new index entry, which forces a new tuple elsewhere,
-- which leaves the old one for vacuum. Dropping it is not a loss — the table is
-- one row per pilot and a sequential scan over a few thousand rows is faster
-- than the index would have been anyway.
drop index if exists public.pilot_live_status_fresh_idx;

-- Room on each page for the new versions to land beside the old ones. Without
-- free space HOT cannot happen however few indexes there are: a full page has
-- nowhere to put the update.
alter table public.pilot_live_status set (fillfactor = 70);

-- And tell autovacuum this table is not like the others. The defaults wait for
-- 20% of the table to be dead, which on a 300-row table is 60 rows — reached in
-- under a minute of flying, and then not acted on until the next naptime.
alter table public.pilot_live_status set (
  autovacuum_vacuum_scale_factor = 0.05,
  autovacuum_vacuum_threshold = 25,
  autovacuum_analyze_scale_factor = 0.10
);

-- MARK: - The ATC exchange
--
-- Infinite Flight's Connect API can stream the ATC messages the pilot's own
-- aircraft sends and receives. It is the sim's own log — what this pilot heard
-- on frequency — not a global feed, and it is already public in the game:
-- everybody on the frequency heard it too.
--
-- STORED IN THE LIVE ROW ON PURPOSE, AND NOWHERE ELSE. The obvious design is a
-- messages table, and it is the wrong one: a row per message, per pilot, per
-- flight is the one part of this feature that could genuinely bloat a database
-- — hundreds of thousands of rows a month to serve a panel that only ever shows
-- the last few. Keeping them in a capped array inside the ephemeral row means
-- the transcript has exactly the lifetime of the flight it belongs to, is
-- deleted by the same sweep, and adds no table, no index and no growth.
--
-- The cap is enforced here rather than trusted to the client, because "the app
-- only ever sends ten" is a sentence about the version of the app that is
-- running today.
alter table public.pilot_live_status
  add column if not exists atc_messages jsonb;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'pilot_live_status_atc_shape') then
    alter table public.pilot_live_status
      add constraint pilot_live_status_atc_shape check (
        atc_messages is null
        or (jsonb_typeof(atc_messages) = 'array'
            and jsonb_array_length(atc_messages) <= 12
            -- A ceiling on the whole thing as well as on the count. Twelve
            -- messages of unbounded length is still unbounded.
            and pg_column_size(atc_messages) <= 4096)
      );
  end if;
end $$;

comment on column public.pilot_live_status.atc_messages is
  'The last few ATC messages this aircraft sent or received, newest first, as [{"at":iso8601,"from":text,"text":text}]. Capped at 12 entries and 4KB by check constraint. Ephemeral: lives and dies with the live row, and is never written anywhere permanent.';

-- MARK: - Housekeeping
--
-- One function, called on a schedule, that removes everything nothing will read
-- again. Deliberately conservative: it only touches rows whose uselessness is a
-- matter of arithmetic rather than judgement.

create or replace function public.housekeeping()
returns table (task text, removed integer)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_count integer;
begin
  -- Live statuses nobody can read. The TTL is four minutes; this waits five
  -- times that before removing anything, so a pilot whose phone dropped Wi-Fi
  -- for a while reconnects to their own row rather than a new one.
  delete from public.pilot_live_status s
   where s.updated_at < now() - (public.live_status_ttl() * 5);
  get diagnostics v_count = row_count;
  task := 'stale live statuses'; removed := v_count; return next;

  -- Reports that were dealt with a long time ago. The open ones are never
  -- touched — an unresolved report is the queue, and a queue that deletes
  -- itself is not a queue.
  delete from public.profile_reports r
   where r.resolved_at is not null
     and r.resolved_at < now() - interval '180 days';
  get diagnostics v_count = row_count;
  task := 'resolved reports'; removed := v_count; return next;

  return;
end $function$;

revoke all on function public.housekeeping() from public;
revoke all on function public.housekeeping() from anon;
revoke all on function public.housekeeping() from authenticated;

-- MARK: - Running it
--
-- `pilot_live_sweep` already existed and was never called by anything, which
-- made it a comment rather than a mechanism. pg_cron is what turns it into one.

create extension if not exists pg_cron with schema pg_catalog;

do $$
begin
  -- Idempotent: unscheduling a job that is not there is not an error worth
  -- failing a migration over, and rescheduling keeps this file re-runnable.
  perform cron.unschedule('inflight-housekeeping');
exception
  when others then null;
end $$;

select cron.schedule(
  'inflight-housekeeping',
  '*/10 * * * *',
  $$select public.housekeeping()$$
);

-- MARK: - Serving the exchange
--
-- `pilot_live_status_for` gains one column. Recreated rather than replaced
-- because the return type changes, and written to be correct whether or not
-- 000500 has already been applied.

drop function if exists public.pilot_live_status_for(text);

create function public.pilot_live_status_for(p_handle text)
returns table (
  handle text,
  display_name text,
  avatar_path text,
  is_pro boolean,
  flight_id text,
  server_name text,
  callsign text,
  aircraft text,
  livery text,
  latitude double precision,
  longitude double precision,
  altitude_msl integer,
  altitude_agl integer,
  heading integer,
  ground_speed_knots integer,
  indicated_airspeed_knots integer,
  vertical_speed_fpm integer,
  phase text,
  gear_state integer,
  flaps_state integer,
  spoilers_state integer,
  landing_lights boolean,
  strobe_lights boolean,
  wind_direction integer,
  wind_velocity_knots integer,
  temperature_c integer,
  nearest_airport text,
  next_waypoint text,
  origin_icao text,
  destination_icao text,
  atc_messages jsonb,
  started_at timestamp with time zone,
  updated_at timestamp with time zone
)
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_viewer uuid := auth.uid();
  v_p public.pilot_profiles%rowtype;
begin
  select * into v_p from public.pilot_profiles p
   where p.handle = lower(btrim(coalesce(p_handle, '')));

  if not public.pilot_live_readable(v_p, v_viewer) then return; end if;

  return query
  select v_p.handle,
         coalesce(v_p.display_name, v_p.handle),
         v_p.avatar_path,
         public.is_pro_account(v_p.user_id),
         s.flight_id, s.server_name, s.callsign, s.aircraft, s.livery,
         s.latitude, s.longitude, s.altitude_msl, s.altitude_agl, s.heading,
         s.ground_speed_knots, s.indicated_airspeed_knots, s.vertical_speed_fpm,
         s.phase, s.gear_state, s.flaps_state, s.spoilers_state,
         s.landing_lights, s.strobe_lights,
         s.wind_direction, s.wind_velocity_knots, s.temperature_c,
         s.nearest_airport, s.next_waypoint, s.origin_icao, s.destination_icao,
         s.atc_messages,
         s.started_at, s.updated_at
    from public.pilot_live_status s
   where s.user_id = v_p.user_id
     and s.updated_at > now() - public.live_status_ttl();
end $function$;

grant execute on function public.pilot_live_status_for(text) to anon, authenticated;

-- MARK: - The landing board
--
-- Who among the people you follow has put one down best. Entirely derived from
-- the logbook — no table, no index, no row written anywhere — which is the
-- whole reason it is worth having: a leaderboard that has to be maintained is a
-- leaderboard that goes wrong, and this one cannot disagree with the flights it
-- is computed from.
--
-- Scoped to people you follow rather than global, and that is a product
-- decision rather than a technical one. A global board is won once by whoever
-- flies most and is then a wall somebody else is standing on; a board of the
-- twenty people you actually fly with is a thing you can be on.

create or replace function public.pilot_landing_board(
  p_window_days integer default 30,
  p_limit integer default 25
)
returns table (
  handle text,
  display_name text,
  avatar_path text,
  is_pro boolean,
  best_fpm integer,
  average_fpm integer,
  landings integer,
  greasers integer,
  best_at timestamp with time zone,
  is_self boolean
)
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_viewer uuid := auth.uid();
  v_since timestamptz;
begin
  if v_viewer is null then return; end if;

  -- Bounded both ways: a window of zero is a board with nothing on it, and an
  -- unbounded one is a full table scan somebody can ask for repeatedly.
  v_since := now() - (least(greatest(coalesce(p_window_days, 30), 1), 365) || ' days')::interval;

  return query
  with circle as (
    -- The people you follow, and yourself. Being absent from your own
    -- leaderboard is a strange way to be shown one.
    select f.following_id as user_id from public.pilot_follows f
     where f.follower_id = v_viewer
    union
    select v_viewer
  ),
  measured as (
    select l.user_id,
           l.landing_vertical_speed_fpm as fpm,
           l.landed_at
      from public.pilot_logbook l
      join circle c on c.user_id = l.user_id
     where l.landing_vertical_speed_fpm is not null
       and l.landed_at >= v_since
  )
  select p.handle,
         coalesce(p.display_name, p.handle),
         p.avatar_path,
         public.is_pro_account(p.user_id),
         -- Softest is closest to zero, and the rates are negative — so `max`
         -- is the best landing and `min` would be the worst one presented as
         -- somebody's finest hour.
         max(m.fpm)::integer,
         avg(m.fpm)::integer,
         count(*)::integer,
         count(*) filter (
           where abs(m.fpm) <= public.logbook_greaser_fpm()
         )::integer,
         (array_agg(m.landed_at order by m.fpm desc))[1],
         p.user_id = v_viewer
    from measured m
    join public.pilot_profiles p on p.user_id = m.user_id
   where p.is_public
     and p.moderation_state = 'ok'
     -- The board reads the logbook, so it obeys the logbook's own visibility.
     -- Somebody who has made their flights private is not on it, follower or
     -- not — the leaderboard is not a side door into a private logbook.
     and (p.user_id = v_viewer or p.logbook_visibility in ('public', 'followers'))
     and not exists (
       select 1 from public.pilot_blocks b
        where b.blocker_id = p.user_id and b.blocked_id = v_viewer)
   group by p.handle, p.display_name, p.avatar_path, p.user_id
   order by max(m.fpm) desc
   limit least(greatest(coalesce(p_limit, 25), 1), 100);
end $function$;

grant execute on function public.pilot_landing_board(integer, integer) to authenticated;
