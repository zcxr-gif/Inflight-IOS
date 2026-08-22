-- MARK: - The right flight gets the right landing
--
-- `pilot_logbook_attach_landing` has always had two ways to decide which flight
-- a touchdown belongs to. The first is certain: the simulator's own flight id,
-- which is the same id the public feed uses. The second is a guess, used when
-- the pilot ended their flight before opening the app so there is no current id
-- to read -- and the guess was wrong in a way that is easy to hit and
-- impossible to notice.
--
-- It picked "the most recent flight that has no landing yet". Consider a pilot
-- who flies two legs and opens the app after the second. The simulator holds
-- the landing from leg two. Leg two already has its landing -- it was recorded
-- live, or attached on a previous open -- so the most recent row *without* one
-- is leg one, and leg two's touchdown is written onto leg one. Both rows are
-- now wrong, the logbook has no way to know it, and the number on the landing
-- board belongs to a flight nobody made.
--
-- The fix follows from what the simulator actually holds: it keeps THE LAST
-- landing until the next one. A last landing can only belong to a last flight.
-- So the fallback now takes the pilot's most recent flight full stop, and
-- attaches only if that flight has no landing. If it already has one, there is
-- nothing to do -- which is the correct answer, not a failure.

alter table public.pilot_logbook
  add column if not exists landing_latitude double precision,
  add column if not exists landing_longitude double precision,
  add column if not exists landing_flight_time_seconds integer;

comment on column public.pilot_logbook.landing_latitude is
  'Where the wheels touched, as the simulator reported it. Read on every landing and until now discarded; it is what makes a debrief able to say which runway, and evidence that a held landing belongs to the flight it is being attached to.';

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'pilot_logbook_landing_place') then
    alter table public.pilot_logbook
      add constraint pilot_logbook_landing_place check (
        (landing_latitude is null or landing_latitude between -90 and 90)
        and (landing_longitude is null or landing_longitude between -180 and 180)
        and (landing_flight_time_seconds is null
             or landing_flight_time_seconds between 0 and 86400)
      );
  end if;
end $$;

-- Dropped and recreated rather than overloaded. Every new parameter has a
-- default, so a client that knows only the old argument names still resolves to
-- this function and simply supplies none of them -- which is what keeps an app
-- already on somebody's phone working.
drop function if exists public.pilot_logbook_attach_landing(
  integer, text, integer, numeric, integer, integer, integer, integer);

create or replace function public.pilot_logbook_attach_landing(
  p_vertical_speed_fpm integer,
  p_flight_id text default null,
  p_score integer default null,
  p_g_force numeric default null,
  p_centreline_offset_m integer default null,
  p_aiming_point_offset_m integer default null,
  p_ground_speed_knots integer default null,
  p_airspeed_knots integer default null,
  p_latitude double precision default null,
  p_longitude double precision default null,
  p_flight_time_seconds integer default null
)
returns table (attached boolean, flight_id text, landed_at timestamp with time zone, reason text)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_target uuid;
  v_flight text;
  v_landed timestamptz;
  v_minutes integer;
  v_has_landing boolean;
  v_sim_minutes numeric;
begin
  if v_uid is null then
    raise exception 'Sign in first.' using errcode = 'insufficient_privilege';
  end if;

  -- MARK: What counts as a landing at all
  --
  -- Tighter than the table's check constraint on purpose. The constraint is a
  -- backstop that raises, which reaches the pilot as a failed request; these
  -- refuse cleanly, because a reading the simulator never took is not an error
  -- on anybody's part.
  --
  -- Zero is the simulator saying "nothing recorded". A positive rate is an
  -- aircraft going up. And -3000 fpm is not a firm landing, it is a crash or a
  -- garbage reading, and either way it is not going on a leaderboard.
  if p_vertical_speed_fpm is null
     or p_vertical_speed_fpm >= 0
     or p_vertical_speed_fpm < -3000 then
    return query select false, null::text, null::timestamptz, 'not a landing'::text;
    return;
  end if;

  -- Everything else is nulled rather than refused when it is out of range: one
  -- implausible g reading should not cost the pilot a real touchdown.
  if p_score is not null and (p_score < 0 or p_score > 1000) then p_score := null; end if;
  if p_g_force is not null and (p_g_force <= 0 or p_g_force > 10) then p_g_force := null; end if;
  if p_centreline_offset_m is not null and abs(p_centreline_offset_m) > 500 then
    p_centreline_offset_m := null;
  end if;
  if p_aiming_point_offset_m is not null and abs(p_aiming_point_offset_m) > 20000 then
    p_aiming_point_offset_m := null;
  end if;
  if p_ground_speed_knots is not null
     and (p_ground_speed_knots < 0 or p_ground_speed_knots > 500) then
    p_ground_speed_knots := null;
  end if;
  if p_airspeed_knots is not null
     and (p_airspeed_knots < 0 or p_airspeed_knots > 500) then
    p_airspeed_knots := null;
  end if;
  if p_latitude is not null and abs(p_latitude) > 90 then p_latitude := null; end if;
  if p_longitude is not null and abs(p_longitude) > 180 then p_longitude := null; end if;
  if p_flight_time_seconds is not null
     and (p_flight_time_seconds < 0 or p_flight_time_seconds > 86400) then
    p_flight_time_seconds := null;
  end if;

  -- MARK: Which flight
  if p_flight_id is not null and length(btrim(p_flight_id)) > 0 then
    -- Certain. The simulator named the flight itself.
    select l.id, l.flight_id, l.landed_at, l.minutes,
           l.landing_vertical_speed_fpm is not null
      into v_target, v_flight, v_landed, v_minutes, v_has_landing
      from public.pilot_logbook l
     where l.user_id = v_uid
       and l.flight_id = p_flight_id
     limit 1;
  else
    -- A guess, and now a disciplined one: the last landing can only belong to
    -- the last flight. Two hours is tight enough to be the leg just flown and
    -- loose enough to survive somebody making a cup of tea first.
    select l.id, l.flight_id, l.landed_at, l.minutes,
           l.landing_vertical_speed_fpm is not null
      into v_target, v_flight, v_landed, v_minutes, v_has_landing
      from public.pilot_logbook l
     where l.user_id = v_uid
       and l.landed_at > now() - interval '2 hours'
     order by l.landed_at desc
     limit 1;
  end if;

  if v_target is null then
    return query select false, null::text, null::timestamptz, 'no flight to attach to'::text;
    return;
  end if;

  -- Already measured. Offering the same landing twice is free and is expected
  -- -- the app offers on every catch-up -- so this is an outcome, not a fault.
  if v_has_landing then
    return query select false, v_flight, v_landed, 'already recorded'::text;
    return;
  end if;

  -- MARK: Is this that flight's landing?
  --
  -- The simulator's own elapsed clock for the flight it just finished, against
  -- the block time the tracker measured. They are different measurements and
  -- will not agree closely: the app starts recording when it first sees the
  -- flight on the feed, which on a phone can be well after pushback. So the
  -- tolerance is deliberately loose -- half the flight again, or fifteen
  -- minutes, whichever is more. What it catches is not a discrepancy, it is a
  -- landing from an entirely different flight: the simulator holds the last
  -- one until the next one, so a pilot who has not flown since yesterday is
  -- still holding yesterday's.
  if p_flight_time_seconds is not null and v_minutes is not null and v_minutes > 0 then
    v_sim_minutes := p_flight_time_seconds / 60.0;
    if abs(v_sim_minutes - v_minutes) > greatest(15, v_minutes * 0.5) then
      return query select false, v_flight, v_landed, 'landing belongs to another flight'::text;
      return;
    end if;
  end if;

  update public.pilot_logbook l
     set landing_vertical_speed_fpm = p_vertical_speed_fpm,
         landing_score = coalesce(p_score, l.landing_score),
         landing_g_force = coalesce(p_g_force, l.landing_g_force),
         landing_centreline_offset_m =
           coalesce(p_centreline_offset_m, l.landing_centreline_offset_m),
         landing_aiming_point_offset_m =
           coalesce(p_aiming_point_offset_m, l.landing_aiming_point_offset_m),
         landing_ground_speed_knots =
           coalesce(p_ground_speed_knots, l.landing_ground_speed_knots),
         landing_airspeed_knots = coalesce(p_airspeed_knots, l.landing_airspeed_knots),
         landing_latitude = coalesce(p_latitude, l.landing_latitude),
         landing_longitude = coalesce(p_longitude, l.landing_longitude),
         landing_flight_time_seconds =
           coalesce(p_flight_time_seconds, l.landing_flight_time_seconds),
         source = 'connect'
   where l.id = v_target
     and l.user_id = v_uid
     and l.landing_vertical_speed_fpm is null;

  return query select true, v_flight, v_landed, 'recorded'::text;
end $function$;

revoke all on function public.pilot_logbook_attach_landing(
  integer, text, integer, numeric, integer, integer, integer, integer,
  double precision, double precision, integer) from public;
revoke all on function public.pilot_logbook_attach_landing(
  integer, text, integer, numeric, integer, integer, integer, integer,
  double precision, double precision, integer) from anon;
grant execute on function public.pilot_logbook_attach_landing(
  integer, text, integer, numeric, integer, integer, integer, integer,
  double precision, double precision, integer) to authenticated;
