-- What a pilot is doing right now, from the sim rather than from the map.
--
-- The live feed already tells everybody where every aeroplane is. This is a
-- different thing: it is the aircraft as ITS OWN PILOT'S SIM reports it —
-- gear, flaps, lights, the wind actually hitting the wing, the phase of flight
-- worked out from configuration rather than guessed from altitude. None of it
-- can be derived from the public feed and none of it can be collected
-- server-side, because the Connect API is local to the pilot's own network.
-- The app is the only thing that can see it, so the app is what writes it here.
--
-- WHY THIS IS NOT JUST A COLUMN ON pilot_profiles. It is written every few
-- seconds for the whole of a long-haul and read by anybody looking at the
-- profile. Putting that write traffic on the profile row would mean every
-- profile read contending with it, and would make `updated_at` on a profile
-- meaningless. It also has a lifetime the profile does not: a status is stale
-- after a few minutes and a profile is not.
--
-- PRIVACY. This is real-time position data attached to a named person, which is
-- a different category from anything else in the schema — the logbook is where
-- somebody WAS, and this is where they ARE. So it defaults to followers-only
-- rather than public, and turning it off leaves no row at all rather than a
-- hidden one. Somebody has to choose to broadcast, choose again to broadcast to
-- strangers, and can stop both instantly.

-- MARK: - Who may see it

alter table public.pilot_profiles
  add column if not exists live_visibility text not null default 'followers';

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'pilot_profiles_live_visibility_check'
  ) then
    alter table public.pilot_profiles
      add constraint pilot_profiles_live_visibility_check
      check (live_visibility in ('public', 'followers', 'private'));
  end if;
end $$;

comment on column public.pilot_profiles.live_visibility is
  'Who may see this pilot''s live status. Defaults to followers because real-time position is a different category from the historical logbook.';

-- MARK: - The status

create table if not exists public.pilot_live_status (

  user_id uuid primary key references auth.users (id) on delete cascade,

  -- The live flight id, which is the same id the public feed uses. It is what
  -- lets a viewer tie this row to the aeroplane already drawn on their map.
  flight_id text,
  server_name text check (server_name is null or char_length(server_name) <= 40),
  callsign text check (callsign is null or char_length(callsign) <= 24),
  aircraft text check (aircraft is null or char_length(aircraft) <= 60),
  livery text check (livery is null or char_length(livery) <= 60),

  latitude double precision check (latitude is null or latitude between -90 and 90),
  longitude double precision check (longitude is null or longitude between -180 and 180),
  altitude_msl integer check (altitude_msl is null or altitude_msl between -2000 and 90000),
  altitude_agl integer check (altitude_agl is null or altitude_agl between -2000 and 90000),
  heading integer check (heading is null or heading between 0 and 360),
  ground_speed_knots integer check (ground_speed_knots is null
                                    or ground_speed_knots between 0 and 1200),
  indicated_airspeed_knots integer check (indicated_airspeed_knots is null
                                          or indicated_airspeed_knots between 0 and 1200),
  vertical_speed_fpm integer check (vertical_speed_fpm is null
                                    or vertical_speed_fpm between -30000 and 30000),

  -- Worked out by the app from gear, flaps and rate of climb rather than from
  -- altitude alone, which is the only way to tell an aircraft on approach from
  -- one that has just taken off.
  phase text check (phase is null or phase in
    ('parked', 'taxiing', 'takeoff', 'climb', 'cruise', 'descent', 'approach', 'landed')),

  -- Configuration. The enums are Infinite Flight's, whose numbering is neither
  -- documented nor consistent between aircraft, so they are stored raw and only
  -- ever read as "zero or not" — which is the one interpretation that holds
  -- everywhere.
  gear_state integer,
  flaps_state integer,
  spoilers_state integer,
  parking_brake boolean,
  reverse_thrust boolean,
  landing_lights boolean,
  strobe_lights boolean,

  -- The sim's weather at the aircraft, which is a better thing than the METAR
  -- at the field below: it is what is actually hitting the aeroplane.
  wind_direction integer check (wind_direction is null or wind_direction between 0 and 360),
  wind_velocity_knots integer check (wind_velocity_knots is null
                                     or wind_velocity_knots between 0 and 300),
  temperature_c integer check (temperature_c is null or temperature_c between -100 and 80),

  nearest_airport text check (nearest_airport is null or nearest_airport ~ '^[A-Z0-9]{3,4}$'),
  next_waypoint text check (next_waypoint is null or char_length(next_waypoint) <= 40),
  origin_icao text check (origin_icao is null or origin_icao ~ '^[A-Z0-9]{3,4}$'),
  destination_icao text check (destination_icao is null
                               or destination_icao ~ '^[A-Z0-9]{3,4}$'),

  started_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.pilot_live_status is
  'One row per pilot currently flying with Infinite Flight Connect attached. Written by the app, never by the server; read publicly only through pilot_live_* functions, which apply the profile''s own live_visibility. Rows go stale after a few minutes and are swept.';

create index if not exists pilot_live_status_fresh_idx
  on public.pilot_live_status (updated_at desc);

-- MARK: - How long a status is worth anything
--
-- One number, here, so the writer's heartbeat, the reader's freshness test and
-- the sweeper cannot disagree. Generous relative to the app's write interval:
-- a phone that loses Wi-Fi for a minute mid-cruise should not vanish from
-- everybody's friends list.
create or replace function public.live_status_ttl()
returns interval language sql immutable as $function$ select interval '4 minutes' $function$;

grant execute on function public.live_status_ttl() to anon, authenticated;

-- MARK: - Row-level security
--
-- A client writes its own row and reads its own row, and that is all. Every
-- public view goes through the functions below, which re-derive visibility
-- themselves. Handing PostgREST a selectable table of live positions would mean
-- `?select=*` returns the real-time location of every pilot on the platform.

grant select, insert, update, delete on public.pilot_live_status to authenticated;

alter table public.pilot_live_status enable row level security;

drop policy if exists "Pilots read their own status" on public.pilot_live_status;
create policy "Pilots read their own status"
  on public.pilot_live_status for select
  to authenticated
  using (auth.uid() = user_id);

drop policy if exists "Pilots write their own status" on public.pilot_live_status;
create policy "Pilots write their own status"
  on public.pilot_live_status for insert
  to authenticated
  with check (auth.uid() = user_id);

drop policy if exists "Pilots update their own status" on public.pilot_live_status;
create policy "Pilots update their own status"
  on public.pilot_live_status for update
  to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- Stopping broadcasting deletes the row. There is no "hidden" state: a pilot
-- who turns this off leaves nothing behind to leak later.
drop policy if exists "Pilots stop broadcasting" on public.pilot_live_status;
create policy "Pilots stop broadcasting"
  on public.pilot_live_status for delete
  to authenticated
  using (auth.uid() = user_id);

-- MARK: - Who may read whose

create or replace function public.pilot_live_readable(
  p_profile public.pilot_profiles,
  p_viewer uuid
)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $function$
  -- Null-safe throughout, for the reason spelled out on `pilot_profile_visible`:
  -- a signed-out reader is NULL, and a comparison against NULL that reaches
  -- `if not ...` fails open.
  select coalesce(
    public.pilot_profile_visible(p_profile, p_viewer)
    and (
      p_profile.user_id is not distinct from p_viewer
      or p_profile.live_visibility = 'public'
      or (p_profile.live_visibility = 'followers'
          and p_viewer is not null
          and exists (
            select 1 from public.pilot_follows f
             where f.follower_id = p_viewer
               and f.following_id = p_profile.user_id))
    ), false);
$function$;

-- MARK: - One pilot's status

create or replace function public.pilot_live_status_for(p_handle text)
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
         s.started_at, s.updated_at
    from public.pilot_live_status s
   where s.user_id = v_p.user_id
     -- Stale is the same as absent. A pilot whose phone went in a pocket over
     -- the Atlantic should stop being "flying now" rather than being shown at a
     -- position they left an hour ago.
     and s.updated_at > now() - public.live_status_ttl();
end $function$;

grant execute on function public.pilot_live_status_for(text) to anon, authenticated;

-- MARK: - Everybody you follow who is flying right now
--
-- The reason the feature is worth building. A friends list that says who is in
-- the air, where, and what they are doing is the thing people open the app for.

create or replace function public.pilot_live_following(p_limit integer default 50)
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
         s.origin_icao, s.destination_icao, s.nearest_airport,
         s.updated_at
    from public.pilot_follows f
    join public.pilot_profiles p on p.user_id = f.following_id
    join public.pilot_live_status s on s.user_id = p.user_id
   where f.follower_id = v_viewer
     and s.updated_at > now() - public.live_status_ttl()
     and p.is_public
     and p.moderation_state = 'ok'
     -- The follow is not enough on its own: `live_visibility` is a separate
     -- decision from being followable, and 'private' means private even to
     -- somebody who follows you.
     and p.live_visibility in ('public', 'followers')
     and not exists (
       select 1 from public.pilot_blocks b
        where b.blocker_id = p.user_id and b.blocked_id = v_viewer)
   order by s.updated_at desc
   limit least(greatest(coalesce(p_limit, 50), 1), 200);
end $function$;

grant execute on function public.pilot_live_following(integer) to anon, authenticated;

-- MARK: - Stopping

-- Explicit rather than leaving it to the DELETE policy, so the app has one call
-- that means "I have stopped flying" and does not have to know the table name.
create or replace function public.pilot_live_clear()
returns void
language sql
security definer
set search_path to 'public'
as $function$
  delete from public.pilot_live_status s where s.user_id = auth.uid();
$function$;

grant execute on function public.pilot_live_clear() to authenticated;

-- Sweeps rows nobody will ever read again.
--
-- The read functions already ignore anything stale, so this is housekeeping
-- rather than correctness — but a table of live positions that only ever grows
-- is a table of historical positions, which is not what anybody agreed to.
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
   where s.updated_at < now() - (public.live_status_ttl() * 5);
  get diagnostics v_removed = row_count;
  return v_removed;
end $function$;

revoke all on function public.pilot_live_sweep() from public;
revoke all on function public.pilot_live_sweep() from anon;
revoke all on function public.pilot_live_sweep() from authenticated;
