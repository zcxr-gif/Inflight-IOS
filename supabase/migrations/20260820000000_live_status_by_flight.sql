-- MARK: - One flight's sim-side status, asked for by flight id
--
-- Every reader so far comes at this table from the pilot: a handle, the people
-- you follow, everybody who chose `public`. The web tracker comes at it from
-- the other end. It is already drawing an aeroplane and it holds one identifier
-- for it -- the live flight id -- so the question it needs answered is "is
-- anybody broadcasting THIS one?".
--
-- Neither existing reader can answer that. `pilot_live_status_for` wants a
-- handle, which is an app account name nobody on the map has; and while
-- `pilot_live_public` is the right audience, it does not return `flight_id` at
-- all, so there is nothing to join the two halves on. The tracker was
-- therefore unable to show a single Connect reading about a flight the pilot
-- was broadcasting at the time, which is what this closes.
--
-- Visibility is not re-decided here. `pilot_live_readable` is the one place
-- that knows who may see whose, and it already covers all three cases: the
-- pilot themselves, `public`, and `followers` for somebody who follows them.
-- Asking by flight id rather than by handle changes the question, not the
-- answer -- and in particular this is not a way to look up a pilot who has
-- their live status switched to followers, because it is the same test.
--
-- The freshness rules are `pilot_live_status_for`'s, for the same reason they
-- exist there: a position is true for four minutes and is nulled in the table
-- when it stops being, while "they were at 3.2 tonnes" is a fact about an
-- aeroplane rather than a location and stays interesting for a day. So a
-- reader gets a position only while there is one, `sim_live_at` to say how old
-- everything else is, and `position_source` to say whether the sim or the feed
-- put the aircraft where it is.

-- Asked for by flight id on every window open, which the freshness index does
-- not help with at all.
create index if not exists pilot_live_status_flight_idx
  on public.pilot_live_status (flight_id)
  where flight_id is not null;

create or replace function public.pilot_live_flight(p_flight_id text)
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
  v_id text := nullif(btrim(coalesce(p_flight_id, '')), '');
begin
  -- An empty id matches every row whose `flight_id` was never written. Reject
  -- it here rather than letting the index find one of them.
  if v_id is null then return; end if;

  return query
  with snapshot as (
    select s.*,
           p.handle as p_handle,
           p.display_name as p_display_name,
           p.avatar_path as p_avatar_path,
           (s.last_live_at > now() - public.live_status_ttl()
            and s.latitude is not null
            and s.longitude is not null) as live
      from public.pilot_live_status s
      join public.pilot_profiles p on p.user_id = s.user_id
     where s.flight_id = v_id
       and coalesce(s.last_live_at, s.updated_at)
             > now() - public.live_last_known_ttl()
       and public.pilot_live_readable(p, v_viewer)
     -- A flight id belongs to one pilot, but nothing in the schema enforces
     -- that, and two rows claiming one aeroplane should resolve to the one
     -- that spoke most recently rather than to whichever the planner reached
     -- first.
     order by coalesce(s.last_live_at, s.updated_at) desc
     limit 1
  )
  select r.p_handle,
         coalesce(r.p_display_name, r.p_handle),
         r.p_avatar_path,
         public.is_pro_account(r.user_id),
         coalesce(r.live, false),

         case when r.live then r.position_source end,
         r.sim_live_at,

         r.flight_id, r.server_name, r.callsign, r.aircraft, r.livery,

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

         r.phase, r.gear_state, r.flaps_state, r.spoilers_state,
         r.landing_lights, r.strobe_lights, r.beacon_lights, r.nav_lights,
         r.parking_brake, r.reverse_thrust, r.transponder_code,
         r.fuel_remaining_kg, r.fuel_burn_kgh,
         r.engine_count, r.engine_n1, r.engine_thrust,
         r.is_stalling, r.is_overspeeding,
         r.wind_direction, r.wind_velocity_knots, r.wind_gust_knots,
         r.temperature_c,
         case when r.live then r.nearest_airport end,
         case when r.live then r.next_waypoint end,
         r.origin_icao, r.destination_icao,
         r.flight_time_seconds, r.app_version,
         case when r.live then r.atc_messages end,
         r.started_at, r.last_live_at, r.updated_at
    from snapshot r;
end $function$;

comment on function public.pilot_live_flight(text) is
  'One broadcasting pilot''s sim-side status, found by the live flight id the public feed uses, applying the same live_visibility test as every other reader. For map clients that hold a flight id and no handle.';

grant execute on function public.pilot_live_flight(text) to anon, authenticated;
