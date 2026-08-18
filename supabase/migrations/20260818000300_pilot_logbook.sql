-- The logbook, and the badges that come out of it.
--
-- The tracker has always known when somebody's aeroplane left the ground and
-- when it stopped moving, and has always thrown that away the moment the
-- aircraft dropped out of the feed. This is where it goes instead: one row per
-- flight, written by the app when a flight it recognises as YOURS ends, and
-- read back as the numbers on a profile.
--
-- Not the same thing as `public.user_flights`, and deliberately not merged with
-- it. That table is a hand-typed PIREP — gates, fuel, passengers, remarks —
-- filed on the website by somebody who wanted a record of a flight. This one is
-- observed: nobody types it, nothing in it is a claim, and every column is
-- something the feed actually reported. Folding the two together would mean a
-- typed number and a measured one sharing a column, and no way to tell a
-- profile's readers which they were looking at.
--
-- WHAT A FREE ACCOUNT GETS. Everything is recorded for everybody -- a logbook
-- that stops recording is not a logbook, and a lapsed subscription must not
-- lose somebody their history. What Pro buys is reading it back: the whole
-- history rather than the most recent stretch of it, and the breakdowns.
-- Totals and badges are all-time for everyone, because a career total that
-- changes when you stop paying is a lie about how much you have flown.

create table if not exists public.pilot_logbook (

  id uuid primary key default gen_random_uuid(),

  user_id uuid not null references auth.users (id) on delete cascade,

  -- The live feed's own id for the flight, which is what makes this
  -- idempotent: the app can post the same completed flight twice -- from a
  -- retry, from a second device watching the same pilot -- and the second one
  -- lands on the unique index instead of in the logbook.
  flight_id text,

  server text check (server is null or char_length(server) <= 40),
  callsign text check (callsign is null or char_length(callsign) <= 24),

  -- Who the feed said was flying. Kept on the row rather than read from the
  -- profile, because a pilot who changes their Infinite Flight handle has not
  -- retrospectively flown their old flights under the new one.
  if_username text check (if_username is null or char_length(if_username) <= 40),

  aircraft text check (aircraft is null or char_length(aircraft) <= 60),
  livery text check (livery is null or char_length(livery) <= 60),

  origin_icao text check (origin_icao is null or origin_icao ~ '^[A-Z0-9]{3,4}$'),
  destination_icao text
    check (destination_icao is null or destination_icao ~ '^[A-Z0-9]{3,4}$'),

  departed_at timestamptz,
  landed_at timestamptz not null default now(),

  -- Block time as the tracker measured it. Capped at 24 hours on the way in:
  -- anything longer is a flight the app watched across a re-spawn, not a
  -- flight, and one bad row would sit at the top of a leaderboard forever.
  minutes integer not null default 0 check (minutes >= 0 and minutes <= 1440),

  distance_nm integer check (distance_nm is null
                             or (distance_nm >= 0 and distance_nm <= 20000)),
  max_altitude_feet integer check (max_altitude_feet is null
                                   or (max_altitude_feet >= 0
                                       and max_altitude_feet <= 90000)),
  top_ground_speed_knots integer check (top_ground_speed_knots is null
                                        or (top_ground_speed_knots >= 0
                                            and top_ground_speed_knots <= 1200)),

  created_at timestamptz not null default now()
);

create unique index if not exists pilot_logbook_flight_key
  on public.pilot_logbook (user_id, flight_id)
  where flight_id is not null;

create index if not exists pilot_logbook_user_idx
  on public.pilot_logbook (user_id, landed_at desc);

comment on table public.pilot_logbook is
  'Flights the tracker watched to their end, one row each. Written by the app for its own pilot; read publicly only through the pilot_logbook_* functions.';

grant select, insert, delete on public.pilot_logbook to authenticated;

alter table public.pilot_logbook enable row level security;

drop policy if exists "Pilots read their own logbook" on public.pilot_logbook;
create policy "Pilots read their own logbook"
  on public.pilot_logbook for select
  to authenticated
  using (auth.uid() = user_id);

drop policy if exists "Pilots write their own logbook" on public.pilot_logbook;
create policy "Pilots write their own logbook"
  on public.pilot_logbook for insert
  to authenticated
  with check (auth.uid() = user_id);

-- Deleting a flight is allowed; editing one is not. A logbook you can rewrite
-- is a logbook nobody reading a profile has any reason to believe. Somebody who
-- flew a leg they would rather not have on their profile can take it off, and
-- what is left is still only ever something the tracker saw.
drop policy if exists "Pilots delete from their own logbook" on public.pilot_logbook;
create policy "Pilots delete from their own logbook"
  on public.pilot_logbook for delete
  to authenticated
  using (auth.uid() = user_id);

-- MARK: - Who may read a logbook
--
-- Its own control, next to the friends list's, for the same reason: the flights
-- somebody has made say where they were and when, and that is a different
-- decision from whether their picture is public.

alter table public.pilot_profiles
  add column if not exists logbook_visibility text not null default 'public';

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conname = 'pilot_profiles_logbook_visibility_check'
  ) then
    alter table public.pilot_profiles
      add constraint pilot_profiles_logbook_visibility_check
      check (logbook_visibility in ('public', 'followers', 'private'));
  end if;
end $$;

-- How much of it a free account's readers get. One number, here, so the
-- function that serves the entries and the copy that explains the limit cannot
-- disagree about it.
create or replace function public.pilot_logbook_free_entries()
returns integer language sql immutable as $function$ select 20 $function$;

grant execute on function public.pilot_logbook_free_entries() to anon, authenticated;

create or replace function public.pilot_logbook_readable(
  p_profile public.pilot_profiles,
  p_viewer uuid
)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $function$
  -- Null-safe throughout, for the reason spelled out on
  -- `pilot_profile_visible`: a signed-out reader is NULL, and a comparison
  -- against NULL that reaches `if not ...` fails open.
  select coalesce(
    public.pilot_profile_visible(p_profile, p_viewer)
    and (
      p_profile.user_id is not distinct from p_viewer
      or p_profile.logbook_visibility = 'public'
      or (p_profile.logbook_visibility = 'followers'
          and p_viewer is not null
          and exists (
            select 1 from public.pilot_follows f
             where f.follower_id = p_viewer
               and f.following_id = p_profile.user_id))
    ), false);
$function$;

-- MARK: - The numbers on a profile
--
-- All-time, for everybody. See the note at the top: a career total is not a
-- Pro feature.

create or replace function public.pilot_logbook_summary(p_handle text)
returns table (
  flights integer,
  minutes integer,
  distance_nm integer,
  airports integer,
  aircraft_types integer,
  regions integer,
  longest_minutes integer,
  longest_distance_nm integer,
  highest_feet integer,
  first_flight_at timestamptz,
  last_flight_at timestamptz,
  top_aircraft text,
  top_route text
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

  if not public.pilot_logbook_readable(v_p, v_viewer) then return; end if;

  return query
  with book as (
    select * from public.pilot_logbook l where l.user_id = v_p.user_id
  ),
  fields as (
    select origin_icao as icao from book where origin_icao is not null
    union all
    select destination_icao from book where destination_icao is not null
  )
  select
    (select count(*)::integer from book),
    (select coalesce(sum(b.minutes), 0)::integer from book b),
    (select coalesce(sum(b.distance_nm), 0)::integer from book b),
    (select count(distinct f.icao)::integer from fields f),
    (select count(distinct b.aircraft)::integer from book b where b.aircraft is not null),
    -- The first letter of an ICAO code is its region -- K is the contiguous
    -- United States, E northern Europe, Y Australia. Not a country count and
    -- not sold as one, but it is a real measure of how far somebody's flying
    -- ranges, and it costs no lookup table.
    (select count(distinct left(f.icao, 1))::integer from fields f),
    (select coalesce(max(b.minutes), 0)::integer from book b),
    (select coalesce(max(b.distance_nm), 0)::integer from book b),
    (select coalesce(max(b.max_altitude_feet), 0)::integer from book b),
    (select min(b.landed_at) from book b),
    (select max(b.landed_at) from book b),
    (select b.aircraft from book b
      where b.aircraft is not null
      group by b.aircraft order by count(*) desc, b.aircraft asc limit 1),
    (select b.origin_icao || ' → ' || b.destination_icao from book b
      where b.origin_icao is not null and b.destination_icao is not null
      group by b.origin_icao, b.destination_icao
      order by count(*) desc, b.origin_icao asc limit 1);
end $function$;

grant execute on function public.pilot_logbook_summary(text) to anon, authenticated;

-- MARK: - The flights themselves
--
-- Where the free limit actually bites, and the only place it does. A free
-- account's logbook is served most-recent-first and stops after
-- `pilot_logbook_free_entries()`; everything before that stays in the table,
-- untouched, and is served again the moment the account is Pro. Nothing is
-- deleted for lapsing.
--
-- `truncated` comes back so the client can say WHY the list stopped rather than
-- leaving somebody to conclude the tracker lost their flights.

create or replace function public.pilot_logbook_entries(
  p_handle text,
  p_limit integer default 50,
  p_offset integer default 0
)
returns table (
  id uuid,
  flight_id text,
  server text,
  callsign text,
  aircraft text,
  livery text,
  origin_icao text,
  destination_icao text,
  departed_at timestamptz,
  landed_at timestamptz,
  minutes integer,
  distance_nm integer,
  max_altitude_feet integer,
  top_ground_speed_knots integer,
  truncated boolean
)
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_viewer uuid := auth.uid();
  v_p public.pilot_profiles%rowtype;
  v_free integer := public.pilot_logbook_free_entries();
  v_ceiling integer;
  v_total integer;
begin
  select * into v_p from public.pilot_profiles p
   where p.handle = lower(btrim(coalesce(p_handle, '')));

  if not public.pilot_logbook_readable(v_p, v_viewer) then return; end if;

  select count(*) into v_total from public.pilot_logbook l where l.user_id = v_p.user_id;

  -- The entitlement checked is the LOGBOOK OWNER'S, not the reader's. A Pro
  -- account's history is open to everybody it is open to; a free account's is
  -- capped for everybody, its owner included. The other way round -- charging
  -- the reader to see somebody else's flights -- would be a paywall on other
  -- people's work.
  v_ceiling := case when public.is_pro_account(v_p.user_id)
                    then 2147483647 else v_free end;

  return query
  select l.id, l.flight_id, l.server, l.callsign, l.aircraft, l.livery,
         l.origin_icao, l.destination_icao, l.departed_at, l.landed_at,
         l.minutes, l.distance_nm, l.max_altitude_feet, l.top_ground_speed_knots,
         (v_total > v_ceiling)
    from (
      select * from public.pilot_logbook lb
       where lb.user_id = v_p.user_id
       order by lb.landed_at desc
       limit v_ceiling
    ) l
   order by l.landed_at desc
   limit least(greatest(coalesce(p_limit, 50), 1), 200)
  offset greatest(coalesce(p_offset, 0), 0);
end $function$;

grant execute on function public.pilot_logbook_entries(text, integer, integer)
  to anon, authenticated;

-- MARK: - Badges
--
-- Derived, never stored. A badge that lives in a table is a badge somebody has
-- to remember to award, a backfill to write when the rule changes, and a row
-- that can be inserted by hand; a badge that is a query over the logbook is
-- true by construction and is re-earned correctly the moment a flight is
-- deleted.
--
-- Every badge is returned whether it has been earned or not, with where the
-- pilot is against it, so the profile can show the next one as something to
-- fly towards rather than showing an empty shelf to everybody new.

create or replace function public.pilot_badges(p_handle text)
returns table (
  code text,
  family text,
  title text,
  detail text,
  target integer,
  progress integer,
  earned boolean
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

  -- Badges follow the logbook's visibility, because they ARE the logbook,
  -- rounded off. A private logbook that still announces "500 hours" has not
  -- been kept private.
  if not public.pilot_logbook_readable(v_p, v_viewer) then return; end if;

  return query
  with book as (
    select * from public.pilot_logbook l where l.user_id = v_p.user_id
  ),
  fields as (
    select origin_icao as icao from book where origin_icao is not null
    union all
    select destination_icao from book where destination_icao is not null
  ),
  totals as (
    select
      (select coalesce(sum(b.minutes), 0) / 60 from book b)                    as hours,
      (select count(*) from book)                                              as flights,
      (select count(distinct f.icao) from fields f)                            as airports,
      (select count(distinct b.aircraft) from book b where b.aircraft is not null) as types,
      (select count(distinct left(f.icao, 1)) from fields f)                   as regions,
      (select coalesce(max(b.minutes), 0) from book b)                         as longest,
      (select coalesce(max(b.distance_nm), 0) from book b)                     as furthest
  ),
  ladder(code, family, title, detail, target) as (
    select * from (
      values
        ('hours_10',    'hours',    'First ten',        'Ten hours in the air.',                    10),
        ('hours_50',    'hours',    'Fifty hours',      'Fifty hours flown.',                       50),
        ('hours_100',   'hours',    'Century',          'A hundred hours flown.',                  100),
        ('hours_500',   'hours',    'Five hundred',     'Five hundred hours flown.',               500),
        ('hours_1000',  'hours',    'Four figures',     'A thousand hours flown.',                1000),
        ('flights_10',  'flights',  'Getting going',    'Ten flights logged.',                      10),
        ('flights_100', 'flights',  'Regular',          'A hundred flights logged.',               100),
        ('flights_500', 'flights',  'Rostered',         'Five hundred flights logged.',            500),
        ('fields_10',   'airports', 'Ten fields',       'Ten airports visited.',                    10),
        ('fields_50',   'airports', 'Fifty fields',     'Fifty airports visited.',                  50),
        ('fields_100',  'airports', 'Hundred fields',   'A hundred airports visited.',             100),
        ('fleet_5',     'fleet',    'Type rated',       'Five aircraft types flown.',                5),
        ('fleet_15',    'fleet',    'Whole fleet',      'Fifteen aircraft types flown.',            15),
        ('fleet_30',    'fleet',    'Anything with wings', 'Thirty aircraft types flown.',          30),
        ('region_4',    'reach',    'Four regions',     'Airports across four ICAO regions.',        4),
        ('region_8',    'reach',    'Worldwide',        'Airports across eight ICAO regions.',       8),
        ('long_480',    'endurance','Long haul',        'A single flight of eight hours.',         480),
        ('long_840',    'endurance','Ultra long haul',  'A single flight of fourteen hours.',      840),
        ('far_3000',    'distance', 'Three thousand',   'Three thousand miles in one flight.',    3000),
        ('far_6000',    'distance', 'Six thousand',     'Six thousand miles in one flight.',      6000)
    ) as v(code, family, title, detail, target)
  )
  select l.code, l.family, l.title, l.detail, l.target,
         least(p.value, l.target)::integer,
         p.value >= l.target
    from ladder l
    cross join totals t
    cross join lateral (
      select case l.family
               when 'hours'     then t.hours
               when 'flights'   then t.flights
               when 'airports'  then t.airports
               when 'fleet'     then t.types
               when 'reach'     then t.regions
               when 'endurance' then t.longest
               when 'distance'  then t.furthest
             end as value
    ) p
   order by l.family, l.target;
end $function$;

grant execute on function public.pilot_badges(text) to anon, authenticated;
