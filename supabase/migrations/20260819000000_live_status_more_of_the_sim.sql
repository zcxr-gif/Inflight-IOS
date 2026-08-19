-- Everything else the sim already tells us, and a status that survives the pilot
-- going quiet.
--
-- Three things, and they are one change because they answer one question:
-- "how much fuel has that pilot got left?" -- which needs the number to be
-- published at all, needs it to still be there when the phone goes in a pocket,
-- and needs somebody who is not a follower to be able to see it.
--
-- WHAT WAS BEING THROWN AWAY. `ConnectSession` polls fuel, engine N1, thrust,
-- true airspeed, pitch, bank, squawk, beacon and nav lights, gust, stall and
-- overspeed warnings, elapsed flight time and the sim's own version -- reads
-- them every pass, puts them in the telemetry struct, shows some of them on the
-- pilot's own screen, and published none of them. The columns below are exactly
-- that set. Nothing new is read from the aircraft; what changes is that what is
-- already read stops being discarded at the app boundary.
--
-- WHY LAST-KNOWN IS NOT JUST "STOP DELETING". Real-time position is the one
-- category this schema treats as special, and it stays special: a position has
-- the TTL it always had, and the moment a row stops being live the position
-- columns are nulled in the table itself rather than merely hidden by a read
-- function. What outlives the TTL is the flight -- aircraft, route, phase,
-- fuel, elapsed time -- which is "AK123 was at 3.2 tonnes an hour ago", not
-- "here is where they were an hour ago". Turning the share switch off still
-- deletes the whole row, unchanged: `pilot_live_clear` is untouched below.

-- MARK: - The rest of the sim

alter table public.pilot_live_status
  -- Fuel, and the reason for the whole migration. Whole kilos: the sim reports
  -- fractional and nobody has ever wanted to know about 400 grams.
  add column if not exists fuel_remaining_kg integer
    check (fuel_remaining_kg is null or fuel_remaining_kg between 0 and 1000000),

  -- Derived here rather than sent, because the client cannot compute it: the
  -- app is suspended behind Infinite Flight for most of a flight and sees its
  -- own samples in bursts. The server sees the whole sequence. See the trigger.
  add column if not exists fuel_burn_kgh integer
    check (fuel_burn_kgh is null or fuel_burn_kgh between 0 and 200000),

  add column if not exists engine_count smallint
    check (engine_count is null or engine_count between 0 and 12),
  -- N1 goes past 100 on a hot day and thrust goes negative in reverse, so
  -- neither is clamped to the range a spec sheet would suggest.
  add column if not exists engine_n1 integer
    check (engine_n1 is null or engine_n1 between -10 and 150),
  add column if not exists engine_thrust integer
    check (engine_thrust is null or engine_thrust between -120 and 150),

  add column if not exists true_airspeed_knots integer
    check (true_airspeed_knots is null or true_airspeed_knots between 0 and 1500),
  add column if not exists pitch integer
    check (pitch is null or pitch between -90 and 90),
  add column if not exists bank integer
    check (bank is null or bank between -180 and 180),

  -- Squawk is octal in the world and an integer here; 7777 is the largest legal
  -- one and the digits are not checked, because an aircraft mid-dial genuinely
  -- reports 1289 on its way to 1200.
  add column if not exists transponder_code integer
    check (transponder_code is null or transponder_code between 0 and 7777),

  add column if not exists beacon_lights boolean,
  add column if not exists nav_lights boolean,

  add column if not exists wind_gust_knots integer
    check (wind_gust_knots is null or wind_gust_knots between 0 and 400),

  add column if not exists is_stalling boolean,
  add column if not exists is_overspeeding boolean,

  -- The sim's own clock for this flight, which is a better elapsed time than
  -- `now() - started_at`: that one starts when the app connected, and this one
  -- starts when the flight did.
  add column if not exists flight_time_seconds integer
    check (flight_time_seconds is null or flight_time_seconds between 0 and 259200),

  add column if not exists app_state text
    check (app_state is null or char_length(app_state) <= 24),
  add column if not exists app_version text
    check (app_version is null or char_length(app_version) <= 24),

  -- The freshness clock, split off from `updated_at`.
  --
  -- `updated_at` now means "this row was written", which a stand-down also
  -- does. Liveness has to mean "a sim was attached and reporting a position",
  -- which is what this is -- and it is set by the trigger below from the
  -- server's clock, never by the client.
  add column if not exists last_live_at timestamptz;

comment on column public.pilot_live_status.fuel_remaining_kg is
  'Fuel on board in whole kilograms, as the aircraft''s own sim reports it. Outlives the position TTL: this is the number people ask about after somebody has gone quiet.';

comment on column public.pilot_live_status.fuel_burn_kgh is
  'Kilograms per hour, smoothed, derived server-side from consecutive fuel readings. Null until two usable samples exist, and reset by a refuel or an aircraft change.';

comment on column public.pilot_live_status.last_live_at is
  'When a sample carrying a position last arrived. Set server-side; the sole test for whether a row is live. `updated_at` is any write, including a stand-down.';

-- Existing rows predate the column and are as live as their last write.
update public.pilot_live_status set last_live_at = updated_at where last_live_at is null;

-- MARK: - How long a last-known reading is worth anything
--
-- Separate number from `live_status_ttl`, and much larger, because it is
-- answering a different question. Four minutes is how long a POSITION is true
-- enough to draw. A day is how long "they were at 3.2 tonnes" stays interesting
-- -- which is roughly the longest flight anybody flies plus the evening they
-- spend talking about it.
create or replace function public.live_last_known_ttl()
returns interval language sql immutable as $function$ select interval '24 hours' $function$;

grant execute on function public.live_last_known_ttl() to anon, authenticated;

-- MARK: - The clocks, and the burn
--
-- One BEFORE trigger owning every timestamp on the row, because all three of
-- the things that read them -- the freshness gate, the sweeper and the burn
-- calculation -- are wrong if the client is the one deciding what time it is.
-- The app has always sent `updated_at`; it is now ignored. A phone with a clock
-- an hour fast was previously able to look live for an hour after it stopped,
-- and one an hour slow was invisible while flying.

create or replace function public.pilot_live_status_stamp()
returns trigger
language plpgsql
as $function$
declare
  v_seconds double precision;
  v_burned  double precision;
  v_rate    double precision;
begin
  new.updated_at := now();

  -- A sample with a position is a live sample. A stand-down nulls the position,
  -- so it writes the row without claiming the pilot is still flying -- which is
  -- the whole mechanism, expressed as one condition.
  if new.latitude is not null and new.longitude is not null then
    new.last_live_at := now();
  end if;

  if TG_OP = 'INSERT' then
    -- Nothing to compare a first sample against.
    new.fuel_burn_kgh := null;
    return new;
  end if;

  new.last_live_at := coalesce(new.last_live_at, old.last_live_at);

  -- Burn carries forward unless this pair of samples says otherwise. An
  -- estimate that blanked itself every time two writes landed close together
  -- would be null most of the time.
  new.fuel_burn_kgh := old.fuel_burn_kgh;

  if new.fuel_remaining_kg is null or old.fuel_remaining_kg is null then
    return new;
  end if;

  -- A different aeroplane is a different flight and nothing carries over. So is
  -- more fuel than last time: that is a refuel or a spawn, not a negative burn.
  if new.aircraft is distinct from old.aircraft
     or new.fuel_remaining_kg > old.fuel_remaining_kg then
    new.fuel_burn_kgh := null;
    return new;
  end if;

  v_seconds := extract(epoch from (now() - old.updated_at));

  -- Both ends matter. Under a minute is mostly rounding -- fuel is stored whole,
  -- and a 45-second gap at cruise shows as either zero or two kilos, which
  -- scaled to an hour is a number off by a factor of the interval. Over fifteen
  -- minutes means the app was suspended, and the burn across a gap it did not
  -- watch is an average over a phase change rather than a rate.
  if v_seconds < 60 or v_seconds > 900 then return new; end if;

  v_burned := old.fuel_remaining_kg - new.fuel_remaining_kg;
  v_rate := (v_burned / v_seconds) * 3600;

  -- Above the column's own ceiling this is a bad pair of readings, not an
  -- aeroplane. Returning here rather than clamping keeps the last good estimate.
  if v_rate > 200000 then return new; end if;

  -- Smoothed rather than instantaneous. Fuel is whole kilos and the interval is
  -- under a minute at its shortest, so a raw rate jitters by hundreds of kilos
  -- an hour between consecutive samples while the aeroplane does nothing. The
  -- weighting follows a genuine change -- a descent, a shutdown -- within a few
  -- samples, which is faster than anybody reads the number.
  if old.fuel_burn_kgh is null then
    new.fuel_burn_kgh := round(v_rate);
  else
    new.fuel_burn_kgh := round(old.fuel_burn_kgh * 0.7 + v_rate * 0.3);
  end if;

  return new;
end $function$;

drop trigger if exists pilot_live_status_stamp on public.pilot_live_status;
create trigger pilot_live_status_stamp
  before insert or update on public.pilot_live_status
  for each row execute function public.pilot_live_status_stamp();

-- MARK: - Going quiet without disappearing
--
-- What the app calls when Connect detaches: the sim is gone, so the position is
-- gone, and everything that was true about the flight stays true. Distinct from
-- `pilot_live_clear`, which is the share switch and still deletes the row
-- outright -- somebody who turns broadcasting off leaves nothing behind, which
-- is the promise the original migration made and this one keeps.

create or replace function public.pilot_live_stand_down()
returns void
language sql
security definer
set search_path to 'public'
as $function$
  update public.pilot_live_status s
     set latitude = null,
         longitude = null,
         heading = null,
         altitude_msl = null,
         altitude_agl = null,
         ground_speed_knots = null,
         indicated_airspeed_knots = null,
         true_airspeed_knots = null,
         vertical_speed_fpm = null,
         pitch = null,
         bank = null,
         nearest_airport = null,
         next_waypoint = null,
         -- The transcript goes with the position. It is what this aircraft
         -- heard on a frequency it is no longer on.
         atc_messages = null
   where s.user_id = auth.uid();
$function$;

grant execute on function public.pilot_live_stand_down() to authenticated;

-- MARK: - One pilot's status
--
-- Recreated rather than replaced: the return type gains the new columns and
-- `is_live`.
--
-- The row is returned whether or not it is live, and the position columns are
-- nulled on the way out when it is not. Belt and braces with `stand_down`: that
-- one handles the app closing cleanly, and this one handles the phone that went
-- flat over the Atlantic and never called anything.

drop function if exists public.pilot_live_status_for(text);

create function public.pilot_live_status_for(p_handle text)
returns table (
  handle text,
  display_name text,
  avatar_path text,
  is_pro boolean,
  is_live boolean,
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
  true_airspeed_knots integer,
  vertical_speed_fpm integer,
  pitch integer,
  bank integer,
  phase text,
  gear_state integer,
  flaps_state integer,
  spoilers_state integer,
  landing_lights boolean,
  strobe_lights boolean,
  beacon_lights boolean,
  nav_lights boolean,
  parking_brake boolean,
  reverse_thrust boolean,
  transponder_code integer,
  fuel_remaining_kg integer,
  fuel_burn_kgh integer,
  engine_count smallint,
  engine_n1 integer,
  engine_thrust integer,
  is_stalling boolean,
  is_overspeeding boolean,
  wind_direction integer,
  wind_velocity_knots integer,
  wind_gust_knots integer,
  temperature_c integer,
  nearest_airport text,
  next_waypoint text,
  origin_icao text,
  destination_icao text,
  flight_time_seconds integer,
  app_version text,
  atc_messages jsonb,
  started_at timestamp with time zone,
  last_live_at timestamp with time zone,
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
  with snapshot as (
    -- Live means a fresh sample that still carries a position. Both halves are
    -- needed: a stand-down leaves `last_live_at` where it was -- it is a record
    -- of when the sim was last attached, not a countdown -- so freshness alone
    -- would report a pilot as flying for four more minutes with nothing to draw
    -- them at. Nulling the position is what ends the flight, in the stand-down
    -- and in housekeeping alike, so the position is what the test reads.
    select s.*, (s.last_live_at > now() - public.live_status_ttl()
                 and s.latitude is not null
                 and s.longitude is not null) as live
      from public.pilot_live_status s
     where s.user_id = v_p.user_id
       and coalesce(s.last_live_at, s.updated_at)
             > now() - public.live_last_known_ttl()
  )
  select v_p.handle,
         coalesce(v_p.display_name, v_p.handle),
         v_p.avatar_path,
         public.is_pro_account(v_p.user_id),
         coalesce(r.live, false),
         r.flight_id, r.server_name, r.callsign, r.aircraft, r.livery,

         -- Everything from here to `next_waypoint` describes where the
         -- aeroplane is at this instant, and is true for four minutes.
         case when r.live then r.latitude end,
         case when r.live then r.longitude end,
         case when r.live then r.altitude_msl end,
         case when r.live then r.altitude_agl end,
         case when r.live then r.heading end,
         case when r.live then r.ground_speed_knots end,
         case when r.live then r.indicated_airspeed_knots end,
         case when r.live then r.true_airspeed_knots end,
         case when r.live then r.vertical_speed_fpm end,
         case when r.live then r.pitch end,
         case when r.live then r.bank end,

         -- And everything from here down describes the flight, which is still
         -- the case an hour later.
         r.phase, r.gear_state, r.flaps_state, r.spoilers_state,
         r.landing_lights, r.strobe_lights, r.beacon_lights, r.nav_lights,
         r.parking_brake, r.reverse_thrust, r.transponder_code,
         r.fuel_remaining_kg, r.fuel_burn_kgh,
         r.engine_count, r.engine_n1, r.engine_thrust,
         r.is_stalling, r.is_overspeeding,
         r.wind_direction, r.wind_velocity_knots, r.wind_gust_knots, r.temperature_c,
         case when r.live then r.nearest_airport end,
         case when r.live then r.next_waypoint end,
         r.origin_icao, r.destination_icao,
         r.flight_time_seconds, r.app_version,
         case when r.live then r.atc_messages end,
         r.started_at, r.last_live_at, r.updated_at
    from snapshot r;
end $function$;

grant execute on function public.pilot_live_status_for(text) to anon, authenticated;

-- MARK: - Everybody you follow who is flying right now
--
-- Live-only, unchanged: this is the "who is in the air" list and filling it with
-- people who landed yesterday would make it a different, worse thing. It gains
-- fuel, because "EGLL to KJFK, 2.4t left" is the line that makes the row worth
-- reading.

drop function if exists public.pilot_live_following(integer);

create function public.pilot_live_following(p_limit integer default 50)
returns table (
  handle text,
  display_name text,
  avatar_path text,
  is_pro boolean,
  callsign text,
  aircraft text,
  phase text,
  latitude double precision,
  longitude double precision,
  altitude_msl integer,
  ground_speed_knots integer,
  fuel_remaining_kg integer,
  fuel_burn_kgh integer,
  origin_icao text,
  destination_icao text,
  nearest_airport text,
  updated_at timestamp with time zone
)
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_viewer uuid := auth.uid();
begin
  if v_viewer is null then return; end if;

  return query
  select p.handle,
         coalesce(p.display_name, p.handle),
         p.avatar_path,
         public.is_pro_account(p.user_id),
         s.callsign, s.aircraft, s.phase,
         s.latitude, s.longitude, s.altitude_msl, s.ground_speed_knots,
         s.fuel_remaining_kg, s.fuel_burn_kgh,
         s.origin_icao, s.destination_icao, s.nearest_airport,
         s.last_live_at
    from public.pilot_follows f
    join public.pilot_profiles p on p.user_id = f.following_id
    join public.pilot_live_status s on s.user_id = p.user_id
   where f.follower_id = v_viewer
     and s.last_live_at > now() - public.live_status_ttl()
     -- Same test as `pilot_live_status_for`: a stood-down row is fresh and has
     -- no position, and a row with no position is not somebody to draw.
     and s.latitude is not null
     and s.longitude is not null
     and p.is_public
     and p.moderation_state = 'ok'
     and p.live_visibility in ('public', 'followers')
     and not exists (
       select 1 from public.pilot_blocks b
        where b.blocker_id = p.user_id and b.blocked_id = v_viewer)
   order by s.last_live_at desc
   limit least(greatest(coalesce(p_limit, 50), 1), 200);
end $function$;

grant execute on function public.pilot_live_following(integer) to anon, authenticated;

-- MARK: - Everybody who chose to broadcast to everybody
--
-- The missing half of the feature. `live_visibility` has had a 'public' setting
-- since it was created and nothing could read it: a pilot could opt in to being
-- seen by the world and the world had no query to ask. This is that query.
--
-- It is not a back door. Only rows whose owner set `live_visibility = 'public'`
-- appear -- the default is still followers, and choosing it is still two
-- deliberate steps -- and a signed-out reader is `auth.uid() = null`, which is
-- why the block check is written to survive that.

create or replace function public.pilot_live_public(p_limit integer default 50)
returns table (
  handle text,
  display_name text,
  avatar_path text,
  is_pro boolean,
  callsign text,
  aircraft text,
  phase text,
  latitude double precision,
  longitude double precision,
  altitude_msl integer,
  ground_speed_knots integer,
  fuel_remaining_kg integer,
  fuel_burn_kgh integer,
  origin_icao text,
  destination_icao text,
  nearest_airport text,
  updated_at timestamp with time zone
)
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_viewer uuid := auth.uid();
begin
  return query
  select p.handle,
         coalesce(p.display_name, p.handle),
         p.avatar_path,
         public.is_pro_account(p.user_id),
         s.callsign, s.aircraft, s.phase,
         s.latitude, s.longitude, s.altitude_msl, s.ground_speed_knots,
         s.fuel_remaining_kg, s.fuel_burn_kgh,
         s.origin_icao, s.destination_icao, s.nearest_airport,
         s.last_live_at
    from public.pilot_live_status s
    join public.pilot_profiles p on p.user_id = s.user_id
   where s.last_live_at > now() - public.live_status_ttl()
     and s.latitude is not null
     and s.longitude is not null
     and p.is_public
     and p.moderation_state = 'ok'
     and p.live_visibility = 'public'
     and (v_viewer is null or not exists (
       select 1 from public.pilot_blocks b
        where b.blocker_id = p.user_id and b.blocked_id = v_viewer))
   order by s.last_live_at desc
   limit least(greatest(coalesce(p_limit, 50), 1), 200);
end $function$;

grant execute on function public.pilot_live_public(integer) to anon, authenticated;

-- MARK: - Housekeeping
--
-- Two stages now instead of one, which is what makes last-known safe to keep.
--
-- Stage one strips the position off anything past the live TTL, in the table
-- rather than in a read function. A row that has gone quiet stops being a
-- position within four minutes even if the app never got to say goodbye, so the
-- database is not holding a track of anybody. Stage two removes the row a day
-- later, when the last-known reading has stopped being interesting too.

create or replace function public.housekeeping()
returns table (task text, removed integer)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_count integer;
begin
  -- Positions that have gone stale. Not a delete: the flight, its route and its
  -- fuel are what survive, and they are not a location.
  update public.pilot_live_status s
     set latitude = null,
         longitude = null,
         heading = null,
         altitude_msl = null,
         altitude_agl = null,
         ground_speed_knots = null,
         indicated_airspeed_knots = null,
         true_airspeed_knots = null,
         vertical_speed_fpm = null,
         pitch = null,
         bank = null,
         nearest_airport = null,
         next_waypoint = null,
         atc_messages = null
   where s.last_live_at < now() - public.live_status_ttl()
     -- Only rows that still hold one, or this rewrites every dormant row every
     -- ten minutes forever -- which is exactly the dead-tuple problem the
     -- fillfactor work went in to solve.
     and (s.latitude is not null or s.longitude is not null
          or s.atc_messages is not null or s.altitude_msl is not null);
  get diagnostics v_count = row_count;
  task := 'positions cleared'; removed := v_count; return next;

  -- And the rows themselves, once even the last-known reading is a day old.
  delete from public.pilot_live_status s
   where coalesce(s.last_live_at, s.updated_at) < now() - public.live_last_known_ttl();
  get diagnostics v_count = row_count;
  task := 'stale live statuses'; removed := v_count; return next;

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

-- `pilot_live_sweep` predates `housekeeping` and would now delete last-known
-- rows twenty minutes in, which is the opposite of the point. Brought in line
-- with the retention above rather than left as a loaded gun.
create or replace function public.pilot_live_sweep()
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_removed integer;
begin
  delete from public.pilot_live_status s
   where coalesce(s.last_live_at, s.updated_at) < now() - public.live_last_known_ttl();
  get diagnostics v_removed = row_count;
  return v_removed;
end $function$;

revoke all on function public.pilot_live_sweep() from public;
revoke all on function public.pilot_live_sweep() from anon;
revoke all on function public.pilot_live_sweep() from authenticated;
