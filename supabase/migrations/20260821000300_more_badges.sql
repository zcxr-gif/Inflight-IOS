-- MARK: - More to go after
--
-- The ladder was eight families deep and every one of them counted something
-- the *feed* could see: hours, flights, fields, types, regions, endurance,
-- distance, and greasers. Everything Connect measures — where on the runway,
-- how hard, how straight — was going into the logbook and being read by
-- nothing.
--
-- Recreated rather than extended in place because `pilot_badges` is one
-- function with the ladder inlined, and a ladder is the kind of thing that
-- should read as a single list rather than as a base plus a patch.
--
-- Nothing here invents a measurement. Every family below is a count over
-- columns that already exist, which is what keeps a badge honest: it is a fact
-- about flights that were flown, not a score somebody designed.

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
  -- Consecutive days with a flight on them. Gaps and islands: subtracting a
  -- dense rank from the date gives every run of consecutive days the same
  -- constant, so the runs group themselves.
  days as (
    select distinct date_trunc('day', b.landed_at)::date as d from book b
  ),
  runs as (
    select d, d - (dense_rank() over (order by d))::integer as grp from days
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
          and abs(b.landing_vertical_speed_fpm) <= public.logbook_greaser_fpm()) as greasers,

      -- Everything below this line is new, and everything below this line is a
      -- count over a column that was already being written.
      (select coalesce(sum(b.distance_nm), 0) from book b)                     as odometer,
      (select count(distinct b.livery) from book b where b.livery is not null) as liveries,
      (select count(distinct (b.origin_icao || '-' || b.destination_icao))
         from book b
        where b.origin_icao is not null and b.destination_icao is not null)    as routes,
      (select coalesce(max(len), 0) from (
         select count(*) as len from runs group by grp) s)                     as streak,
      (select count(*) from book b where b.source = 'connect')                 as measured,
      (select count(*) from book b
        where b.landing_centreline_offset_m is not null
          and abs(b.landing_centreline_offset_m) <= 5)                         as centred,
      (select count(*) from book b
        where b.landing_g_force is not null and b.landing_g_force <= 1.2)      as gentle,
      (select count(*) from book b
        where b.landing_aiming_point_offset_m is not null
          and abs(b.landing_aiming_point_offset_m) <= 100)                     as aimed
  ),
  ladder(code, family, title, detail, target) as (
    select * from (
      values
        ('hours_10',    'hours',    'First ten',        'Ten hours in the air.',                    10),
        ('hours_50',    'hours',    'Fifty hours',      'Fifty hours flown.',                       50),
        ('hours_100',   'hours',    'Century',          'A hundred hours flown.',                  100),
        ('hours_500',   'hours',    'Five hundred',     'Five hundred hours flown.',               500),
        ('hours_1000',  'hours',    'Four figures',     'A thousand hours flown.',                1000),
        ('hours_2500',  'hours',    'Command time',     'Two and a half thousand hours flown.',   2500),
        ('flights_10',  'flights',  'Getting going',    'Ten flights logged.',                      10),
        ('flights_100', 'flights',  'Regular',          'A hundred flights logged.',               100),
        ('flights_500', 'flights',  'Rostered',         'Five hundred flights logged.',            500),
        ('flights_1000','flights',  'Senior',           'A thousand flights logged.',             1000),
        ('fields_10',   'airports', 'Ten fields',       'Ten airports visited.',                    10),
        ('fields_50',   'airports', 'Fifty fields',     'Fifty airports visited.',                  50),
        ('fields_100',  'airports', 'Hundred fields',   'A hundred airports visited.',             100),
        ('fields_250',  'airports', 'Everywhere',       'Two hundred and fifty airports visited.', 250),
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
        ('grease_50',   'touch',    'Silk',             'Fifty landings under 100 feet per minute.', 50),

        ('odo_10000',   'odometer', 'Ten thousand',     'Ten thousand miles flown in total.',    10000),
        ('odo_50000',   'odometer', 'Fifty thousand',   'Fifty thousand miles flown in total.',  50000),
        ('odo_250000',  'odometer', 'Quarter million',  'A quarter of a million miles flown.',  250000),

        ('livery_10',   'liveries', 'Ten colours',      'Ten liveries flown.',                      10),
        ('livery_25',   'liveries', 'Paint shop',       'Twenty-five liveries flown.',              25),
        ('livery_60',   'liveries', 'Every scheme',     'Sixty liveries flown.',                    60),

        ('route_10',    'routes',   'Ten routes',       'Ten different city pairs flown.',          10),
        ('route_50',    'routes',   'Network',          'Fifty different city pairs flown.',        50),
        ('route_150',   'routes',   'Timetable',        'A hundred and fifty city pairs flown.',   150),

        ('streak_3',    'streak',   'Three in a row',   'Flown on three consecutive days.',          3),
        ('streak_7',    'streak',   'Full week',        'Flown on seven consecutive days.',          7),
        ('streak_30',   'streak',   'Whole month',      'Flown on thirty consecutive days.',        30),

        ('connect_1',   'measured', 'Wired in',         'A flight measured by Infinite Flight Connect.', 1),
        ('connect_25',  'measured', 'Instrumented',     'Twenty-five flights measured by Connect.', 25),
        ('connect_100', 'measured', 'Flight data',      'A hundred flights measured by Connect.',  100),

        ('centre_1',    'precision','On the paint',     'A touchdown within five metres of the centreline.', 1),
        ('centre_10',   'precision','Down the middle',  'Ten touchdowns within five metres of the centreline.', 10),
        ('centre_50',   'precision','Surveyed',         'Fifty touchdowns within five metres of the centreline.', 50),

        ('aim_10',      'aim',      'On the numbers',   'Ten touchdowns within 100 m of the aiming point.', 10),
        ('aim_50',      'aim',      'Spot on',          'Fifty touchdowns within 100 m of the aiming point.', 50),

        ('gentle_10',   'gforce',   'Feather',          'Ten touchdowns at 1.2 g or less.',         10),
        ('gentle_50',   'gforce',   'Soft hands',       'Fifty touchdowns at 1.2 g or less.',       50)
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
               when 'odometer'  then t.odometer
               when 'liveries'  then t.liveries
               when 'routes'    then t.routes
               when 'streak'    then t.streak
               when 'measured'  then t.measured
               when 'precision' then t.centred
               when 'aim'       then t.aimed
               when 'gforce'    then t.gentle
             end as value
    ) p
   order by l.family, l.target;
end $function$;

grant execute on function public.pilot_badges(text) to anon, authenticated;
