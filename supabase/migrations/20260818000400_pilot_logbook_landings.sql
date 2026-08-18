-- What the wheels were doing when they touched the runway.
--
-- Every number the logbook has held so far was INFERRED from the public live
-- feed: position several seconds apart, and a landing worked out from the fact
-- that an aeroplane which was in the sky is now on the ground. That is good
-- enough for block time and distance flown and hopeless for the one number
-- pilots actually argue about, because a touchdown lasts a fraction of a second
-- and the feed samples either side of it.
--
-- The Connect API measures it in the sim and hands over the answer. It is a
-- local-network API — it works only when the pilot is flying with a second
-- device on the same Wi-Fi — so these columns are nullable throughout and most
-- rows will never carry them. That is the design, not a shortcoming: a logbook
-- that only recorded flights flown at home would be a worse logbook.
--
-- `source` is what keeps the two honest. A row measured by the sim and a row
-- inferred from the feed are different kinds of claim, and a profile that shows
-- a landing rate should be able to say which it is looking at.

alter table public.pilot_logbook
  add column if not exists source text not null default 'feed',

  -- Feet per minute at touchdown, negative going down, which is how every
  -- pilot reads it. The floor is generous: an aircraft arriving at more than
  -- 6,000 fpm has crashed rather than landed, and one bad row would sit at the
  -- bottom of every leaderboard forever.
  add column if not exists landing_vertical_speed_fpm integer,

  -- Infinite Flight's own grade. Range is not documented, so the constraint is
  -- wide enough to accept whatever it sends and narrow enough to reject a
  -- misread float.
  add column if not exists landing_score integer,

  -- Peak g through the flare. Two decimals, because the difference between
  -- 1.18 and 1.2 is the difference between a good landing and a very good one.
  add column if not exists landing_g_force numeric(4,2),

  -- Metres off the centreline, and metres long or short of the 1,000ft aiming
  -- point. Both signed: which side, and long or short, are the interesting part.
  add column if not exists landing_centreline_offset_m integer,
  add column if not exists landing_aiming_point_offset_m integer,

  add column if not exists landing_ground_speed_knots integer,
  add column if not exists landing_airspeed_knots integer;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'pilot_logbook_source_check') then
    alter table public.pilot_logbook
      add constraint pilot_logbook_source_check check (source in ('feed', 'connect'));
  end if;

  if not exists (select 1 from pg_constraint where conname = 'pilot_logbook_landing_ranges') then
    alter table public.pilot_logbook
      add constraint pilot_logbook_landing_ranges check (
        (landing_vertical_speed_fpm is null
          or landing_vertical_speed_fpm between -6000 and 600)
        and (landing_score is null or landing_score between 0 and 1000)
        and (landing_g_force is null or landing_g_force between 0 and 10)
        and (landing_centreline_offset_m is null
          or landing_centreline_offset_m between -500 and 500)
        and (landing_aiming_point_offset_m is null
          or landing_aiming_point_offset_m between -20000 and 20000)
        and (landing_ground_speed_knots is null
          or landing_ground_speed_knots between 0 and 500)
        and (landing_airspeed_knots is null
          or landing_airspeed_knots between 0 and 500)
      );
  end if;
end $$;

comment on column public.pilot_logbook.source is
  '''feed'' when the flight was inferred from the public live feed, ''connect'' when the sim measured it over the Connect API. A landing rate only exists on the latter.';

-- Only measured rows are ever read for a landing statistic, and they are a
-- minority of the table. A partial index keeps the summary cheap without
-- carrying an entry for every row that has nothing to say.
create index if not exists pilot_logbook_landing_idx
  on public.pilot_logbook (user_id, landing_vertical_speed_fpm)
  where landing_vertical_speed_fpm is not null;

-- MARK: - What counts as a greaser
--
-- One number, in one place, so the badge ladder and the copy that explains it
-- cannot drift apart. 100 fpm is the figure the Infinite Flight community
-- treats as the threshold; it is not ours to invent and not worth arguing over.
create or replace function public.logbook_greaser_fpm()
returns integer language sql immutable as $function$ select 100 $function$;

grant execute on function public.logbook_greaser_fpm() to anon, authenticated;

-- MARK: - The summary, now with landings
--
-- Dropped and recreated rather than replaced: the return type gains columns,
-- and `create or replace function` cannot change a function's signature.

drop function if exists public.pilot_logbook_summary(text);

create function public.pilot_logbook_summary(p_handle text)
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
  first_flight_at timestamp with time zone,
  last_flight_at timestamp with time zone,
  top_aircraft text,
  top_route text,
  -- Everything below is measured rather than inferred, and is null for a pilot
  -- who has never flown with Connect attached.
  landings_measured integer,
  best_landing_fpm integer,
  average_landing_fpm integer,
  recent_landing_fpm integer,
  greasers integer,
  best_landing_score integer
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
  ),
  landed as (
    select * from book b where b.landing_vertical_speed_fpm is not null
  )
  select
    (select count(*)::integer from book),
    (select coalesce(sum(b.minutes), 0)::integer from book b),
    (select coalesce(sum(b.distance_nm), 0)::integer from book b),
    (select count(distinct f.icao)::integer from fields f),
    (select count(distinct b.aircraft)::integer from book b where b.aircraft is not null),
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
      order by count(*) desc, b.origin_icao asc limit 1),

    (select count(*)::integer from landed),

    -- "Best" is the softest touchdown, which is the one CLOSEST TO ZERO rather
    -- than the smallest number. The rates are negative, so `max` is the right
    -- aggregate and `min` would proudly report the hardest arrival of somebody's
    -- career as their finest moment.
    (select max(l.landing_vertical_speed_fpm)::integer from landed l),

    (select avg(l.landing_vertical_speed_fpm)::integer from (
       select landing_vertical_speed_fpm from landed
        order by landed_at desc limit 10
     ) l),

    (select l.landing_vertical_speed_fpm::integer from landed l
      order by l.landed_at desc limit 1),

    (select count(*)::integer from landed l
      where abs(l.landing_vertical_speed_fpm) <= public.logbook_greaser_fpm()),

    (select max(l.landing_score)::integer from landed l);
end $function$;

grant execute on function public.pilot_logbook_summary(text) to anon, authenticated;

-- MARK: - The entries, now carrying what was measured

drop function if exists public.pilot_logbook_entries(text, integer, integer);

create function public.pilot_logbook_entries(
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
  departed_at timestamp with time zone,
  landed_at timestamp with time zone,
  minutes integer,
  distance_nm integer,
  max_altitude_feet integer,
  top_ground_speed_knots integer,
  source text,
  landing_vertical_speed_fpm integer,
  landing_score integer,
  landing_g_force numeric,
  landing_centreline_offset_m integer,
  landing_aiming_point_offset_m integer,
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

  -- The entitlement checked is the LOGBOOK OWNER'S, not the reader's, exactly
  -- as before. Charging a reader to see somebody else's flights would be a
  -- paywall on other people's work.
  v_ceiling := case when public.is_pro_account(v_p.user_id)
                    then 2147483647 else v_free end;

  return query
  select l.id, l.flight_id, l.server, l.callsign, l.aircraft, l.livery,
         l.origin_icao, l.destination_icao, l.departed_at, l.landed_at,
         l.minutes, l.distance_nm, l.max_altitude_feet, l.top_ground_speed_knots,
         l.source,
         l.landing_vertical_speed_fpm, l.landing_score, l.landing_g_force,
         l.landing_centreline_offset_m, l.landing_aiming_point_offset_m,
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

-- MARK: - Badges for the touchdown
--
-- Same rules as every other badge: derived, never stored, and returned whether
-- earned or not so a new pilot sees something to fly towards. The `touch`
-- family is the only one that needs Connect — a pilot who has never used it
-- sees the ladder sitting at zero, which is honest.

drop function if exists public.pilot_badges(text);

create function public.pilot_badges(p_handle text)
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
      (select coalesce(max(b.distance_nm), 0) from book b)                     as furthest,
      (select count(*) from book b
        where b.landing_vertical_speed_fpm is not null
          and abs(b.landing_vertical_speed_fpm) <= public.logbook_greaser_fpm()) as greasers
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
        ('far_6000',    'distance', 'Six thousand',     'Six thousand miles in one flight.',      6000),
        ('grease_1',    'touch',    'Greaser',          'A landing under 100 feet per minute.',      1),
        ('grease_10',   'touch',    'Ten of those',     'Ten landings under 100 feet per minute.',  10),
        ('grease_50',   'touch',    'Silk',             'Fifty landings under 100 feet per minute.', 50)
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
               when 'touch'     then t.greasers
             end as value
    ) p
   order by l.family, l.target;
end $function$;

grant execute on function public.pilot_badges(text) to anon, authenticated;
