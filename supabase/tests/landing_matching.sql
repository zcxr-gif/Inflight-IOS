-- Which flight a touchdown is written onto.
--
-- The bug this file exists for is silent by construction: a landing attached to
-- the wrong leg looks exactly like a landing attached to the right one, and the
-- only evidence is a number on a leaderboard belonging to a flight nobody made.
--
-- Run with `supabase/tests/run.sh`.

\set ON_ERROR_STOP on
\pset pager off

begin;

insert into auth.users (id) values ('cccccccc-0000-0000-0000-000000000001');
insert into public.pilot_profiles (user_id, handle) values
  ('cccccccc-0000-0000-0000-000000000001', 'sam');

create or replace function pg_temp.acting_as(p_user text) returns void
language sql as $$ select set_config('request.jwt.claim.sub', p_user, false)::void $$;

do $$
declare
  r record;
  sam uuid := 'cccccccc-0000-0000-0000-000000000001';
begin
  perform pg_temp.acting_as(sam::text);

  -- Two legs, an hour apart. Leg two is the one just flown.
  -- Distinct landing times throughout. Inside one transaction `now()` is a
  -- single instant, so two rows written with it are tied and "the most recent
  -- flight" stops meaning anything -- which is a property of the test, not of
  -- production, where each flight is written in its own transaction.
  insert into public.pilot_logbook (user_id, flight_id, callsign, landed_at, minutes)
  values (sam, 'leg-one', 'BAW1', now() - interval '90 minutes', 60),
         (sam, 'leg-two', 'BAW2', now() - interval '60 minutes', 55);

  -- 1. Named by the simulator, it goes exactly where it is told.
  select * into r from public.pilot_logbook_attach_landing(
    p_vertical_speed_fpm => -142, p_flight_id => 'leg-two');
  assert r.attached, 'a landing with a flight id attaches';
  assert r.flight_id = 'leg-two', 'and to that flight';

  select landing_vertical_speed_fpm into r from public.pilot_logbook where flight_id = 'leg-one';
  assert r.landing_vertical_speed_fpm is null, 'the other leg is untouched';

  -- 2. The bug. With no flight id, the old rule picked the most recent flight
  --    WITHOUT a landing -- which is leg one, an hour before the touchdown the
  --    simulator is holding. The last landing belongs to the last flight or to
  --    nothing.
  select * into r from public.pilot_logbook_attach_landing(p_vertical_speed_fpm => -142);
  assert not r.attached, 'a held landing is not pushed onto an older leg';
  assert r.reason = 'already recorded', format('and says why, got %s', r.reason);

  select landing_vertical_speed_fpm into r from public.pilot_logbook where flight_id = 'leg-one';
  assert r.landing_vertical_speed_fpm is null, 'leg one still has no landing on it';

  -- 3. A last flight without a landing does take one.
  insert into public.pilot_logbook (user_id, flight_id, callsign, landed_at, minutes)
  values (sam, 'leg-three', 'BAW3', now() - interval '40 minutes', 40);

  select * into r from public.pilot_logbook_attach_landing(p_vertical_speed_fpm => -95);
  assert r.attached, 'the last flight takes the held landing';
  assert r.flight_id = 'leg-three', 'and it is the last flight';

  -- 4. A landing from a flight of a completely different length is refused.
  insert into public.pilot_logbook (user_id, flight_id, callsign, landed_at, minutes)
  values (sam, 'leg-four', 'BAW4', now() - interval '30 minutes', 30);

  select * into r from public.pilot_logbook_attach_landing(
    p_vertical_speed_fpm => -180, p_flight_time_seconds => 39600);  -- eleven hours
  assert not r.attached, 'a landing from an eleven-hour flight is not this thirty-minute one';
  assert r.reason = 'landing belongs to another flight', format('reason was %s', r.reason);

  -- ...and a plausible one is taken, with a loose tolerance, because block time
  -- and the sim clock are different measurements.
  select * into r from public.pilot_logbook_attach_landing(
    p_vertical_speed_fpm => -180, p_flight_time_seconds => 2100);   -- 35 minutes
  assert r.attached, 'a flight time within tolerance still attaches';

  -- 5. Tight on what counts as a landing.
  insert into public.pilot_logbook (user_id, flight_id, landed_at, minutes)
  values (sam, 'leg-five', now() - interval '20 minutes', 20);

  select * into r from public.pilot_logbook_attach_landing(p_vertical_speed_fpm => 0);
  assert not r.attached, 'zero is the sim saying nothing was recorded';

  select * into r from public.pilot_logbook_attach_landing(p_vertical_speed_fpm => 320);
  assert not r.attached, 'an aircraft going up has not landed';

  select * into r from public.pilot_logbook_attach_landing(p_vertical_speed_fpm => -9000);
  assert not r.attached, 'nine thousand feet a minute is not a firm landing';

  -- 6. A garbage score costs the score, not the landing.
  select * into r from public.pilot_logbook_attach_landing(
    p_vertical_speed_fpm => -110, p_score => 99999, p_g_force => 42);
  assert r.attached, 'an implausible score does not cost a real touchdown';

  select * into r from public.pilot_logbook where flight_id = 'leg-five';
  assert r.landing_vertical_speed_fpm = -110, 'the rate is kept';
  assert r.landing_score is null, 'and the impossible score is dropped';
  assert r.landing_g_force is null, 'as is the impossible g';

  -- 7. Where it touched down is kept, now that it is asked for.
  insert into public.pilot_logbook (user_id, flight_id, landed_at, minutes)
  values (sam, 'leg-six', now() - interval '10 minutes', 20);

  select * into r from public.pilot_logbook_attach_landing(
    p_vertical_speed_fpm => -120, p_latitude => 51.4775, p_longitude => -0.4614);
  assert r.attached, 'a landing with a position attaches';

  select * into r from public.pilot_logbook where flight_id = 'leg-six';
  assert r.landing_latitude between 51.47 and 51.48, 'and the position is kept';

  raise notice 'landing matching: 20 assertions passed';
end $$;

rollback;

-- MARK: - The badge ladder
--
-- Not a taste test: what is asserted is that every family resolves to a number.
-- The `case` in the badge query returns NULL for a family nobody wired up, and
-- a NULL progress is a badge that renders as blank and can never be earned --
-- which is exactly how a new family gets added and quietly does nothing.

begin;

insert into auth.users (id) values ('dddddddd-0000-0000-0000-000000000001');
insert into public.pilot_profiles (user_id, handle, logbook_visibility) values
  ('dddddddd-0000-0000-0000-000000000001', 'tam', 'public');

do $$
declare
  n integer;
  r record;
  tam uuid := 'dddddddd-0000-0000-0000-000000000001';
begin
  -- Three consecutive days, two routes, two liveries, all measured by Connect,
  -- all put down straight and softly.
  insert into public.pilot_logbook
    (user_id, flight_id, aircraft, livery, origin_icao, destination_icao,
     landed_at, minutes, distance_nm, source,
     landing_vertical_speed_fpm, landing_g_force,
     landing_centreline_offset_m, landing_aiming_point_offset_m)
  values
    (tam, 'b1', 'A350-900', 'British Airways', 'EGLL', 'KJFK',
     now() - interval '2 days', 420, 3000, 'connect', -95, 1.05, 2, 40),
    (tam, 'b2', 'A350-900', 'Qatar',           'KJFK', 'EGLL',
     now() - interval '1 day',  400, 3000, 'connect', -110, 1.10, 3, 60),
    (tam, 'b3', 'B777-300ER', 'British Airways', 'EGLL', 'LFPG',
     now(),                     60,  200,  'connect', -180, 1.30, 40, 900);

  select count(*) into n from public.pilot_badges('tam');
  assert n > 40, format('the ladder has grown, got %s rungs', n);

  select count(*) into n from public.pilot_badges('tam') where progress is null;
  assert n = 0, 'every family resolves to a number, so no badge is unearnable';

  select * into r from public.pilot_badges('tam') where code = 'streak_3';
  assert r.progress = 3, format('three consecutive days counted, got %s', r.progress);
  assert r.earned, 'and the streak badge is earned';

  select * into r from public.pilot_badges('tam') where code = 'route_10';
  assert r.progress = 3, format('three distinct city pairs, got %s', r.progress);

  select * into r from public.pilot_badges('tam') where code = 'connect_1';
  assert r.earned, 'a Connect-measured flight earns the first measured badge';

  select * into r from public.pilot_badges('tam') where code = 'centre_1';
  assert r.earned, 'a touchdown within five metres of the centreline counts';
  select * into r from public.pilot_badges('tam') where code = 'centre_10';
  assert r.progress = 2, format('and only the two that were, got %s', r.progress);

  select * into r from public.pilot_badges('tam') where code = 'odo_10000';
  assert r.progress = 6200, format('total distance adds up, got %s', r.progress);

  -- Two, not three: one of the three flights repeats a livery, which is the
  -- point of counting distinct ones.
  select * into r from public.pilot_badges('tam') where code = 'livery_10';
  assert r.progress = 2, format('two distinct liveries, got %s', r.progress);

  select * into r from public.pilot_badges('tam') where code = 'gentle_10';
  assert r.progress = 2, format('two touchdowns at 1.2 g or less, got %s', r.progress);

  select * into r from public.pilot_badges('tam') where code = 'aim_10';
  assert r.progress = 2, format('two within 100 m of the aiming point, got %s', r.progress);

  raise notice 'badges: 13 assertions passed';
end $$;

rollback;
