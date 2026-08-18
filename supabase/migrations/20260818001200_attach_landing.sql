-- Completing a logbook row after the fact.
--
-- WHY THIS EXISTS. On one device the app cannot watch the touchdown happen:
-- while you are flying, Infinite Flight is in front and Inflight is suspended.
-- But the simulator HOLDS the last landing until the next one, so the landing
-- is still there to be read when you come back — which means the flight can be
-- recorded by the live feed as it always is, and the measurement attached
-- afterwards.
--
-- WHY IT IS A FUNCTION AND NOT AN UPDATE POLICY. `pilot_logbook` deliberately
-- has no UPDATE policy at all: "a logbook you can rewrite is a logbook nobody
-- reading a profile has any reason to believe". That stays true. This runs as
-- the owner and can do exactly one thing — fill in landing columns that are
-- still empty, on a row that is already yours. It cannot change a flight's
-- time, distance, route or altitude, and it cannot overwrite a landing that has
-- already been recorded. The row only ever becomes more complete.

create or replace function public.pilot_logbook_attach_landing(
  p_vertical_speed_fpm integer,
  p_flight_id text default null,
  p_score integer default null,
  p_g_force numeric default null,
  p_centreline_offset_m integer default null,
  p_aiming_point_offset_m integer default null,
  p_ground_speed_knots integer default null,
  p_airspeed_knots integer default null
)
returns table (attached boolean, flight_id text, landed_at timestamp with time zone)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_target uuid;
  v_flight text;
  v_landed timestamptz;
begin
  if v_uid is null then
    raise exception 'Sign in first.' using errcode = 'insufficient_privilege';
  end if;

  -- A landing rate of exactly zero is the simulator saying "nothing recorded",
  -- not a perfect touchdown. Nothing to attach.
  if p_vertical_speed_fpm is null or p_vertical_speed_fpm = 0 then
    return query select false, null::text, null::timestamptz;
    return;
  end if;

  -- Which flight this belongs to.
  --
  -- The simulator's own flight id when it still reports one, because that is
  -- certain. When the pilot has already ended the flight there is no current
  -- id, so it falls back to the most recent flight that has no landing yet —
  -- bounded to two hours, which is tight enough to be the leg just flown and
  -- loose enough to survive somebody making a cup of tea first.
  select l.id, l.flight_id, l.landed_at
    into v_target, v_flight, v_landed
    from public.pilot_logbook l
   where l.user_id = v_uid
     and l.landing_vertical_speed_fpm is null
     and (
       (p_flight_id is not null and l.flight_id = p_flight_id)
       or (p_flight_id is null and l.landed_at > now() - interval '2 hours')
     )
   order by l.landed_at desc
   limit 1;

  if v_target is null then
    return query select false, null::text, null::timestamptz;
    return;
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
         -- The flight was still worked out from the feed; only the touchdown
         -- was measured. `connect` is the honest label for a row that now
         -- carries a real landing rate.
         source = 'connect'
   where l.id = v_target
     -- Belt and braces: the select already required both, and this is the
     -- statement that actually writes.
     and l.user_id = v_uid
     and l.landing_vertical_speed_fpm is null;

  return query select true, v_flight, v_landed;
end $function$;

revoke all on function public.pilot_logbook_attach_landing(
  integer, text, integer, numeric, integer, integer, integer, integer) from public;
revoke all on function public.pilot_logbook_attach_landing(
  integer, text, integer, numeric, integer, integer, integer, integer) from anon;
grant execute on function public.pilot_logbook_attach_landing(
  integer, text, integer, numeric, integer, integer, integer, integer) to authenticated;
