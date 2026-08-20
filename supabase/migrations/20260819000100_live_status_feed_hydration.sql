-- Keeping a broadcast flight on the map after the pilot switches to the sim.
--
-- THE PROBLEM. Infinite Flight Connect is a LAN API served by the sim to
-- whatever is on the same Wi-Fi, so only the pilot's own device can read it --
-- and on a phone, the moment they switch to Infinite Flight, iOS suspends
-- Inflight and the socket dies with it. There is no honest way around that:
-- the background modes that hold a socket open for fourteen hours are `audio`
-- and `location`, and claiming either to poll a flight simulator would be a
-- lie to the user and to App Review.
--
-- The consequence, until now, was that a pilot who turned broadcasting on
-- vanished from everybody else's friends list about four minutes into the
-- flight -- at exactly the point the flight got interesting.
--
-- THE FIX, AND WHY IT IS NOT A CLIMBDOWN. `flight_id` on this row is the same
-- id the public live feed uses; that join is the whole reason the app reads it
-- out of the sim. So the server -- which cannot see Connect and never will --
-- can see that same aeroplane on the public feed, and keep the position fresh
-- from there while the app is suspended. What it cannot fill in is everything
-- Connect exists for: fuel, gear, flaps, lights, the wind at the wing. Those
-- stay exactly as the sim last reported them, and gain a clock of their own so
-- a reader can say "3.2 t, fourteen minutes ago" instead of implying it is now.
--
-- PRIVACY, BECAUSE THIS WRITES POSITIONS THE PILOT DID NOT SEND. Three things
-- make that the same promise as before rather than a weakening of it:
--
--   * There is no row unless the pilot turned broadcasting on. Hydration finds
--     rows; it never creates one. The share switch still deletes.
--   * The position comes from the public feed, which already shows that
--     aeroplane to everybody with or without this table.
--   * Nothing accumulates. It is the same upserted row, housekeeping still
--     strips the position four minutes after the last sample of either kind,
--     and the row still expires within the day.
--
-- The second half of the file is the notice. A pilot whose Connect link drops
-- mid-flight currently learns about it when they next open the app, which is
-- the one moment they can see it on screen anyway; `ConnectSession` cannot
-- announce a reconnection it is suspended too deeply to attempt. The server
-- can see the drop -- their flight is on the feed and their sim has gone quiet
-- -- so the server is what says so, once per flight.

-- MARK: - Where a position came from, and when the sim last spoke

alter table public.pilot_live_status
  -- Which of the two writers put the current position there. Null when there
  -- is no position at all, which is what a stood-down or swept row looks like.
  add column if not exists position_source text
    check (position_source is null or position_source in ('connect', 'feed')),

  -- When a sample from the SIM last carried a position.
  --
  -- `last_live_at` now means "a position of either kind arrived", because that
  -- is what every liveness test in the schema is asking. This is the narrower
  -- question the Connect-only columns need: fuel, configuration and the sim's
  -- weather are only as current as this, however recently the aeroplane moved
  -- on the map.
  add column if not exists sim_live_at timestamptz,

  -- The flight the drop notice has already been sent for. Dedupe lives here
  -- rather than in the backend's memory so a redeploy mid-flight does not send
  -- a second one, and so it resets by itself when the next flight starts.
  add column if not exists connect_alert_flight_id text;

comment on column public.pilot_live_status.position_source is
  'Which writer put the current position there: ''connect'' for the pilot''s own sim, ''feed'' for the server filling the gap from the public live feed while their app is suspended. Null when there is no position.';

comment on column public.pilot_live_status.sim_live_at is
  'When a sample from the sim last carried a position. Everything Connect-only on this row -- fuel, configuration, lights, sim weather -- is as old as this, not as old as `last_live_at`.';

comment on column public.pilot_live_status.connect_alert_flight_id is
  'The flight a "stopped reading your sim" notice has already gone out for. One per flight, and only ever set server-side.';

-- Existing rows only ever had sim samples, so the sim clock is the live clock.
update public.pilot_live_status
   set sim_live_at = last_live_at
 where sim_live_at is null;

update public.pilot_live_status
   set position_source = 'connect'
 where position_source is null
   and latitude is not null
   and longitude is not null;

-- MARK: - Whether a pilot wants to hear about it at all

alter table public.pilot_profiles
  add column if not exists connect_alerts boolean not null default true;

comment on column public.pilot_profiles.connect_alerts is
  'Whether to notify this pilot when their Infinite Flight Connect link drops mid-flight. A notification with no off switch is a bad notification.';

-- MARK: - The clocks, again
--
-- Recreated rather than patched, because two of its decisions change and both
-- are load-bearing.
--
-- WHO IS WRITING is now a question the trigger has to answer, and it answers it
-- from a transaction-local setting the hydrator sets rather than from a column
-- the client could fill in. A client that could name itself 'connect' could
-- also name itself 'feed', and the difference decides whether a fuel reading is
-- presented as current.
--
-- THE BURN INTERVAL now measures from `sim_live_at` instead of `updated_at`.
-- It always should have -- it is a rate between two fuel readings, and fuel
-- only ever arrives from the sim -- but until there was a second writer the two
-- clocks were the same and the bug was invisible. With hydration they are not:
-- a row written every thirty seconds by the server would have made every pair
-- of sim samples look thirty seconds apart, which is inside the sixty-second
-- floor, so the burn rate would simply have stopped being calculated.

create or replace function public.pilot_live_status_stamp()
returns trigger
language plpgsql
as $function$
declare
  v_feed    boolean := coalesce(current_setting('inflight.hydrating', true), '') = '1';
  v_seconds double precision;
  v_burned  double precision;
  v_rate    double precision;
  v_since   timestamptz;
begin
  new.updated_at := now();

  -- A sample with a position is a live sample, whichever writer sent it. A
  -- stand-down nulls the position, so it writes the row without claiming the
  -- pilot is still flying -- which is the whole mechanism, expressed as one
  -- condition.
  if new.latitude is not null and new.longitude is not null then
    new.last_live_at := now();
    if v_feed then
      new.position_source := 'feed';
    else
      new.position_source := 'connect';
      new.sim_live_at := now();
    end if;
  else
    -- No position, no source. Keeps a stood-down row from claiming its absent
    -- position came from anywhere.
    new.position_source := null;
  end if;

  if TG_OP = 'INSERT' then
    -- Nothing to compare a first sample against.
    new.fuel_burn_kgh := null;
    return new;
  end if;

  new.last_live_at := coalesce(new.last_live_at, old.last_live_at);
  new.sim_live_at  := coalesce(new.sim_live_at, old.sim_live_at);

  -- Burn carries forward unless this pair of samples says otherwise. An
  -- estimate that blanked itself every time two writes landed close together
  -- would be null most of the time.
  new.fuel_burn_kgh := old.fuel_burn_kgh;

  -- A hydrate carries no fuel reading, so there is no pair and nothing to say.
  -- Returning here rather than falling through is the difference between the
  -- estimate surviving a suspended app and being dragged to zero by a server
  -- that reported the same fuel figure back to itself every thirty seconds.
  if v_feed then return new; end if;

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

  v_since := coalesce(old.sim_live_at, old.updated_at);
  v_seconds := extract(epoch from (now() - v_since));

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

  if old.fuel_burn_kgh is null then
    new.fuel_burn_kgh := round(v_rate);
  else
    new.fuel_burn_kgh := round(old.fuel_burn_kgh * 0.7 + v_rate * 0.3);
  end if;

  return new;
end $function$;

-- MARK: - Standing down, with the source

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
         position_source = null,
         -- The transcript goes with the position. It is what this aircraft
         -- heard on a frequency it is no longer on.
         atc_messages = null
   where s.user_id = auth.uid();
$function$;

grant execute on function public.pilot_live_stand_down() to authenticated;

-- MARK: - What the server should be looking for
--
-- The backend holds every flight on every server in memory already. All it
-- needs from here is which feed ids are worth matching, which is a list of
-- public identifiers and nothing else -- no handle, no account, no position.
-- Service role only regardless, because the set of ids is also the set of
-- pilots who have opted into broadcasting.

create or replace function public.pilot_live_hydratable()
returns table (flight_id text)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select s.flight_id
    from public.pilot_live_status s
   where s.flight_id is not null
     -- Still within the day the row is kept for. Past that it is going to be
     -- deleted rather than refreshed.
     and coalesce(s.last_live_at, s.updated_at) > now() - public.live_last_known_ttl()
   limit 5000;
$function$;

revoke all on function public.pilot_live_hydratable() from public;
revoke all on function public.pilot_live_hydratable() from anon;
revoke all on function public.pilot_live_hydratable() from authenticated;

-- Explicit rather than left to the project's default privileges. This is the
-- one caller there is, and a function the backend cannot execute fails as a
-- permission error in a log nobody reads rather than as a missing feature.
grant execute on function public.pilot_live_hydratable() to service_role;

-- MARK: - Filling the gap
--
-- One statement for a whole snapshot: the backend posts every matched flight it
-- can see and this applies the ones that are actually gaps.
--
-- The gate is `sim_live_at`, not `last_live_at`. The sim is authoritative
-- whenever it is talking -- it samples four times a second against the feed's
-- fifteen -- so hydration only ever touches a row whose sim has already gone
-- quiet past the TTL. A pilot flying on an iPad in Split View, with Connect
-- attached for the whole flight, is never hydrated at all.

create or replace function public.pilot_live_hydrate(p_rows jsonb)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_count integer;
begin
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then return 0; end if;

  -- Transaction-local, read by the stamp trigger. The alternative -- a column
  -- saying which writer this is -- would be a claim the client could also make.
  perform set_config('inflight.hydrating', '1', true);

  update public.pilot_live_status s
     set latitude = r.latitude,
         longitude = r.longitude,
         altitude_msl = r.altitude_msl,
         heading = r.heading,
         ground_speed_knots = r.ground_speed_knots,
         vertical_speed_fpm = r.vertical_speed_fpm,
         -- Deliberately not written: everything the feed cannot see. Fuel,
         -- gear, flaps, lights, N1, the wind at the aircraft and the ATC
         -- transcript all stay as the sim last reported them, aged by
         -- `sim_live_at`. A feed-derived guess at any of them would be worse
         -- than an honest timestamp.
         altitude_agl = null,
         indicated_airspeed_knots = null,
         true_airspeed_knots = null,
         pitch = null,
         bank = null
    from jsonb_to_recordset(p_rows) as r (
           flight_id text,
           latitude double precision,
           longitude double precision,
           altitude_msl integer,
           heading integer,
           ground_speed_knots integer,
           vertical_speed_fpm integer)
   where s.flight_id is not null
     and s.flight_id = r.flight_id
     and r.latitude is not null
     and r.longitude is not null
     and r.latitude between -90 and 90
     and r.longitude between -180 and 180
     -- Only a gap. A sim that is still reporting wins every time.
     and coalesce(s.sim_live_at, '-infinity'::timestamptz)
           < now() - public.live_status_ttl()
     -- And only a row that is still worth keeping at all.
     and coalesce(s.last_live_at, s.updated_at) > now() - public.live_last_known_ttl();

  get diagnostics v_count = row_count;

  perform set_config('inflight.hydrating', '0', true);
  return v_count;
end $function$;

revoke all on function public.pilot_live_hydrate(jsonb) from public;
revoke all on function public.pilot_live_hydrate(jsonb) from anon;
revoke all on function public.pilot_live_hydrate(jsonb) from authenticated;
grant execute on function public.pilot_live_hydrate(jsonb) to service_role;

-- MARK: - Who has just lost their sim link
--
-- Reads and writes in one call on purpose. The alternative is the backend
-- remembering who it has already told, which is a memory that does not survive
-- a redeploy -- and a pilot being told twice on the same flight that their sim
-- has gone quiet is worse than not being told at all.
--
-- Both conditions together are what make this specific rather than nagging:
--
--   * `flight_id` matches a flight on the feed right now. `flight_id` is only
--     ever written by the app, so a match means the app published THIS flight.
--   * `sim_live_at` is set, and stale. So Connect worked on this flight and has
--     since stopped -- rather than never having been attached, which is not
--     news and is not what anyone installed this for.
--
-- Nobody who does not use Connect can be reached by this, because they have no
-- row; nobody who is using it right now can be, because their sim clock is
-- fresh; and nobody hears about the same flight twice.

-- `p_limit` is not a paging convenience. Marking a flight as told and sending
-- the notice are two different systems, and only the first is transactional —
-- so the number claimed here has to be a number the caller will actually get
-- through APNs on this pass. Claiming two hundred and delivering fifty would
-- leave a hundred and fifty pilots marked as told and never told, which is the
-- one outcome worse than telling nobody. The overflow is simply still due on
-- the next pass.

create or replace function public.pilot_connect_alerts_due(
  p_flight_ids text[],
  p_limit integer default 100
)
returns table (user_id uuid, handle text, flight_id text, callsign text)
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if p_flight_ids is null or array_length(p_flight_ids, 1) is null then return; end if;

  return query
  with due as (
    select s.user_id
      from public.pilot_live_status s
      join public.pilot_profiles p on p.user_id = s.user_id
     where s.flight_id = any (p_flight_ids)
       and s.sim_live_at is not null
       -- Twice the position TTL. One TTL is a Wi-Fi stutter or a phone
       -- answering a call; eight minutes is the app having been put away.
       and s.sim_live_at < now() - (public.live_status_ttl() * 2)
       and s.connect_alert_flight_id is distinct from s.flight_id
       and p.connect_alerts
     -- Longest quiet first, so an overflow delays the pilots who have only
     -- just dropped rather than the ones who have been waiting.
     order by s.sim_live_at
     limit least(greatest(coalesce(p_limit, 100), 1), 500)
  ),
  marked as (
    update public.pilot_live_status s
       set connect_alert_flight_id = s.flight_id
      from due d
     where d.user_id = s.user_id
    returning s.user_id, s.flight_id, s.callsign
  )
  select m.user_id, p.handle, m.flight_id, m.callsign
    from marked m
    join public.pilot_profiles p on p.user_id = m.user_id;
end $function$;

revoke all on function public.pilot_connect_alerts_due(text[], integer) from public;
revoke all on function public.pilot_connect_alerts_due(text[], integer) from anon;
revoke all on function public.pilot_connect_alerts_due(text[], integer) from authenticated;
grant execute on function public.pilot_connect_alerts_due(text[], integer) to service_role;

-- MARK: - Housekeeping, with the source cleared

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
  -- fuel are what survive, and they are not a location. Unchanged by hydration
  -- -- a flight the feed has stopped carrying stops being hydrated, and this is
  -- what then removes it, on exactly the clock it always did.
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
         position_source = null,
         atc_messages = null
   where s.last_live_at < now() - public.live_status_ttl()
     and (s.latitude is not null or s.longitude is not null
          or s.atc_messages is not null or s.altitude_msl is not null
          or s.position_source is not null);
  get diagnostics v_count = row_count;
  task := 'positions cleared'; removed := v_count; return next;

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

-- MARK: - Telling a reader which half is current
--
-- The three readers gain the same two columns, and gain nothing else. Their
-- freshness tests are unchanged and did not need changing: they ask whether a
-- position arrived recently and whether one is still there, and a hydrated row
-- answers both honestly.
--
-- What a client does with the pair is the point of the whole exercise. An
-- aeroplane whose `position_source` is 'feed' is where the map says it is, and
-- its fuel, configuration and lights are as of `sim_live_at` -- which is a
-- caption ("3.2 t · 14 min ago"), not a reason to hide the number. Before this,
-- the same pilot was simply gone.

drop function if exists public.pilot_live_status_for(text);

create function public.pilot_live_status_for(p_handle text)
returns table (
  handle text,
  display_name text,
  avatar_path text,
  is_pro boolean,
  is_live boolean,
  position_source text,
  sim_live_at timestamp with time zone,
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
    -- of when a position last arrived, not a countdown -- so freshness alone
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

         -- Only meaningful while there is a position to attribute.
         case when r.live then r.position_source end,
         -- And this one is meaningful whether or not there is: it is how old
         -- everything below `bank` is.
         r.sim_live_at,

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
         -- the case an hour later -- as of `sim_live_at`, which is why that is
         -- returned above rather than left to be inferred.
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
  position_source text,
  sim_live_at timestamp with time zone,
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
         s.position_source, s.sim_live_at,
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

drop function if exists public.pilot_live_public(integer);

create function public.pilot_live_public(p_limit integer default 50)
returns table (
  handle text,
  display_name text,
  avatar_path text,
  is_pro boolean,
  callsign text,
  aircraft text,
  phase text,
  position_source text,
  sim_live_at timestamp with time zone,
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
         s.position_source, s.sim_live_at,
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
