-- What the live status is supposed to do, asserted rather than eyeballed.
--
-- The interesting behaviour here is all about time and absence -- a row that is
-- fresh, a row that has gone quiet, a row that stood down cleanly, a row whose
-- phone went flat -- and none of it is visible by reading the schema. Every
-- assertion below is a rule the app depends on and would not notice breaking.
--
-- Run with `supabase/tests/run.sh`.

\set ON_ERROR_STOP on
\pset pager off

begin;

-- Three pilots. Alice broadcasts to everybody, Bob follows her, Carol
-- broadcasts to followers only and is the control for the public list.
insert into auth.users (id) values
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222'),
  ('33333333-3333-3333-3333-333333333333');

insert into public.pilot_profiles (user_id, handle, display_name, live_visibility) values
  ('11111111-1111-1111-1111-111111111111', 'alice', 'Alice', 'public'),
  ('22222222-2222-2222-2222-222222222222', 'bob',   'Bob',   'followers'),
  ('33333333-3333-3333-3333-333333333333', 'carol', 'Carol', 'followers');

insert into public.pilot_follows (follower_id, following_id) values
  ('22222222-2222-2222-2222-222222222222', '11111111-1111-1111-1111-111111111111');

-- Moving the clock. Every timestamp on the row is set by the trigger from the
-- server's own `now()`, which is the whole point of it -- so ageing a row means
-- taking the trigger off, backdating, and putting it back.
--
-- All three clocks move together, because this stands in for time passing and
-- time passes for all of them. `sim_live_at` in particular: it is what the fuel
-- burn is now measured against, so leaving it where it was would make every
-- pair of samples in this file look simultaneous.
create or replace function pg_temp.age_by(p_interval interval) returns void
language plpgsql as $$
begin
  alter table public.pilot_live_status disable trigger pilot_live_status_stamp;
  update public.pilot_live_status
     set last_live_at = last_live_at - p_interval,
         sim_live_at  = sim_live_at  - p_interval,
         updated_at   = updated_at - p_interval;
  alter table public.pilot_live_status enable trigger pilot_live_status_stamp;
end $$;

-- Ageing the sim alone: the app suspended, the aeroplane kept flying. This is
-- the state hydration exists for, and it is not reachable through `age_by`.
create or replace function pg_temp.age_sim_by(p_interval interval) returns void
language plpgsql as $$
begin
  alter table public.pilot_live_status disable trigger pilot_live_status_stamp;
  update public.pilot_live_status set sim_live_at = sim_live_at - p_interval;
  alter table public.pilot_live_status enable trigger pilot_live_status_stamp;
end $$;

create or replace function pg_temp.acting_as(p_user text) returns void
language sql as $$ select set_config('request.jwt.claim.sub', p_user, false)::void $$;

do $$
declare
  alice uuid := '11111111-1111-1111-1111-111111111111';
  r record;
  n integer;
begin
  perform pg_temp.acting_as(alice::text);

  -- 1. A first sample stamps the freshness clock from the server, not from the
  --    client -- which used to be able to claim any time it liked.
  insert into public.pilot_live_status
    (user_id, latitude, longitude, altitude_msl, heading, aircraft, callsign,
     origin_icao, destination_icao, fuel_remaining_kg, engine_n1, phase, updated_at)
  values
    (alice, 51.4775, -0.4614, 35000, 270, 'A350-900', 'BAW117',
     'EGLL', 'KJFK', 62000, 88, 'cruise', now() + interval '3 hours');

  select * into r from public.pilot_live_status where user_id = alice;
  assert r.last_live_at is not null, 'a sample with a position sets last_live_at';
  assert r.updated_at < now() + interval '1 minute', 'the client clock is ignored';
  assert r.fuel_burn_kgh is null, 'one sample is not a burn rate';

  -- 2. Two samples five minutes apart are. 500 kg in 5 minutes is 6,000 kg/h.
  perform pg_temp.age_by(interval '5 minutes');
  update public.pilot_live_status
     set fuel_remaining_kg = 61500, latitude = 51.5, longitude = -0.5
   where user_id = alice;

  select * into r from public.pilot_live_status where user_id = alice;
  assert r.fuel_burn_kgh = 6000,
    format('burn should be 6000 kg/h, got %s', r.fuel_burn_kgh);

  -- 3. More fuel than last time is a refuel, not a negative burn.
  update public.pilot_live_status set fuel_remaining_kg = 70000 where user_id = alice;
  select * into r from public.pilot_live_status where user_id = alice;
  assert r.fuel_burn_kgh is null, 'a refuel resets the estimate';

  -- 4. A follower sees the whole thing.
  perform pg_temp.acting_as('22222222-2222-2222-2222-222222222222');
  select * into r from public.pilot_live_status_for('alice');
  assert r.is_live, 'a fresh row with a position is live';
  assert r.latitude is not null, 'a live row carries its position';
  assert r.fuel_remaining_kg = 70000, 'fuel is published';
  assert r.destination_icao = 'KJFK', 'the route is published';

  -- 5. Standing down drops the position and keeps the flight. The row stops
  --    being live immediately -- not four minutes later -- because liveness
  --    tests the position, and this is what just removed it.
  perform pg_temp.acting_as(alice::text);
  perform public.pilot_live_stand_down();

  select * into r from public.pilot_live_status where user_id = alice;
  assert r.latitude is null and r.longitude is null, 'stand-down clears the position';
  assert r.atc_messages is null, 'stand-down clears the transcript';
  assert r.fuel_remaining_kg = 70000, 'stand-down keeps the fuel';
  assert r.aircraft = 'A350-900', 'stand-down keeps the aircraft';

  perform pg_temp.acting_as('22222222-2222-2222-2222-222222222222');
  select * into r from public.pilot_live_status_for('alice');
  assert not r.is_live, 'a stood-down row is not live';
  assert r.latitude is null, 'a stood-down row has no position to serve';
  assert r.fuel_remaining_kg = 70000, 'the last known fuel survives';
  assert r.phase = 'cruise', 'the last known phase survives';

  -- 6. The phone that went flat mid-Atlantic and never stood down. The read
  --    function has to null the position on its own.
  perform pg_temp.acting_as(alice::text);
  update public.pilot_live_status
     set latitude = 51.5, longitude = -0.5, altitude_msl = 35000
   where user_id = alice;
  perform pg_temp.age_by(interval '10 minutes');

  perform pg_temp.acting_as('22222222-2222-2222-2222-222222222222');
  select * into r from public.pilot_live_status_for('alice');
  assert not r.is_live, 'a row past the TTL is not live';
  assert r.latitude is null and r.altitude_msl is null,
    'a stale position is withheld even though the table still holds it';
  assert r.fuel_remaining_kg = 70000, 'the last known fuel still survives';

  -- 7. And housekeeping takes it out of the table, so no track is kept.
  perform public.housekeeping();
  select * into r from public.pilot_live_status where user_id = alice;
  assert r.latitude is null and r.altitude_msl is null,
    'housekeeping clears stale positions in the table itself';
  assert r.fuel_remaining_kg = 70000, 'housekeeping keeps the flight';

  -- 8. The following list is who is flying now, so it drops her.
  perform pg_temp.acting_as('22222222-2222-2222-2222-222222222222');
  select count(*) into n from public.pilot_live_following(50);
  assert n = 0, format('a pilot with no position is not "flying now", got %s rows', n);

  -- 9. Broadcasting to everybody reaches a signed-out reader.
  perform pg_temp.acting_as(alice::text);
  update public.pilot_live_status
     set latitude = 51.5, longitude = -0.5, altitude_msl = 35000,
         fuel_remaining_kg = 60000
   where user_id = alice;

  perform pg_temp.acting_as('');
  select count(*) into n from public.pilot_live_public(50);
  assert n = 1, format('the public list should hold alice alone, got %s', n);
  select * into r from public.pilot_live_public(50);
  assert r.fuel_remaining_kg = 60000, 'the public list carries fuel';

  -- 10. And reaches nobody who did not ask for it.
  perform pg_temp.acting_as('33333333-3333-3333-3333-333333333333');
  insert into public.pilot_live_status (user_id, latitude, longitude, aircraft)
  values ('33333333-3333-3333-3333-333333333333', 40.6, -73.7, 'B738');

  perform pg_temp.acting_as('');
  select count(*) into n from public.pilot_live_public(50)
   where handle = 'carol';
  assert n = 0, 'a followers-only pilot is not on the public list';

  -- 11. The share switch still deletes outright. Last-known is what happens
  --     when a sim goes away, never when somebody withdraws consent.
  perform pg_temp.acting_as(alice::text);
  perform public.pilot_live_clear();
  select count(*) into n from public.pilot_live_status where user_id = alice;
  assert n = 0, 'clearing leaves nothing behind';

  -- 12. Last-known expires by itself after a day.
  perform pg_temp.age_by(interval '25 hours');
  perform public.housekeeping();
  select count(*) into n from public.pilot_live_status;
  assert n = 0, format('day-old rows are swept, got %s left', n);

  raise notice 'live_status: 30 assertions passed';
end $$;

-- Feed hydration, and the notice that goes with it.
--
-- The behaviour under test is a gap: an app that has been suspended behind
-- Infinite Flight, a flight that carried on without it, and a server filling in
-- the position from the public feed while refusing to invent anything the feed
-- cannot see. None of that is visible in the schema either.

do $$
declare
  alice uuid := '11111111-1111-1111-1111-111111111111';
  bob   uuid := '22222222-2222-2222-2222-222222222222';
  carol uuid := '33333333-3333-3333-3333-333333333333';
  r record;
  n integer;

  -- Where the feed says the aeroplane is, an ocean away from the last thing the
  -- sim reported, so no assertion below can pass by accident.
  feed jsonb := jsonb_build_array(jsonb_build_object(
    'flight_id', 'FEED-1',
    'latitude', 40.6,
    'longitude', -73.7,
    'altitude_msl', 33000,
    'heading', 280,
    'ground_speed_knots', 470,
    'vertical_speed_fpm', -500));
begin
  perform pg_temp.acting_as(alice::text);

  insert into public.pilot_live_status
    (user_id, flight_id, latitude, longitude, altitude_msl, heading,
     ground_speed_knots, true_airspeed_knots, aircraft, callsign,
     origin_icao, destination_icao, fuel_remaining_kg, phase)
  values
    (alice, 'FEED-1', 51.4775, -0.4614, 35000, 270, 450, 470,
     'A350-900', 'BAW117', 'EGLL', 'KJFK', 62000, 'cruise');

  -- A burn rate to protect. 500 kg in five minutes is 6,000 kg/h, and it is
  -- measured between two SIM samples -- which is the reason the interval moved
  -- off `updated_at`, a clock the server now also writes.
  perform pg_temp.age_by(interval '5 minutes');
  update public.pilot_live_status
     set fuel_remaining_kg = 61500, latitude = 51.5, longitude = -0.5
   where user_id = alice;

  select * into r from public.pilot_live_status where user_id = alice;
  assert r.fuel_burn_kgh = 6000,
    format('a burn is still measured sim-sample to sim-sample, got %s', r.fuel_burn_kgh);
  assert r.position_source = 'connect', 'a sim sample is a connect position';

  -- 1. While the sim is talking, the feed does not get a say. It samples four
  --    times a second against the feed's fifteen; there is nothing to gain and
  --    a position to lose.
  n := public.pilot_live_hydrate(feed);
  assert n = 0, format('a live sim is never overwritten, got %s rows', n);
  select * into r from public.pilot_live_status where user_id = alice;
  assert r.latitude = 51.5, 'the sim position stands';

  -- 2. Then the pilot switches to Infinite Flight and iOS suspends the app.
  --    Nothing arrives from anywhere, and within the TTL she is off the map --
  --    which is the whole problem this feature exists for.
  perform pg_temp.age_by(interval '5 minutes');
  perform pg_temp.acting_as(bob::text);
  select * into r from public.pilot_live_status_for('alice');
  assert not r.is_live, 'nothing has arrived for five minutes';
  assert r.latitude is null, 'and a stale position is withheld';
  select count(*) into n from public.pilot_live_following(50);
  assert n = 0, format('and she is off the friends list, got %s', n);

  -- 3. The feed fills the gap.
  n := public.pilot_live_hydrate(feed);
  assert n = 1, format('a quiet sim is a gap to fill, got %s rows', n);

  select * into r from public.pilot_live_status_for('alice');
  assert r.is_live, 'a hydrated pilot is on the map again';
  assert r.latitude = 40.6, 'at the position the feed reported';
  assert r.position_source = 'feed', 'and says plainly where that came from';

  -- 4. What the feed cannot see is not guessed at. It is kept, and dated.
  assert r.fuel_remaining_kg = 61500, 'the last sim fuel survives a hydrate';
  assert r.fuel_burn_kgh = 6000,
    format('and so does the burn -- a hydrate is not a fuel sample, got %s', r.fuel_burn_kgh);
  assert r.phase = 'cruise', 'as does the last sim phase';
  assert r.true_airspeed_knots is null, 'and what only the sim knows is not invented';
  assert r.sim_live_at < now() - interval '4 minutes',
    'the sim clock does not move on a hydrate -- it is what ages the fuel';

  -- 5. Which is the point: other people can see her again.
  select count(*) into n from public.pilot_live_following(50);
  assert n = 1, format('a hydrated pilot is back on her follower''s list, got %s', n);
  perform pg_temp.acting_as('');
  select count(*) into n from public.pilot_live_public(50) where handle = 'alice';
  assert n = 1, format('and on the public list, signed out, got %s', n);

  -- 6. The notice. Four minutes of quiet is a phone answering a call; ten is
  --    the app having been put away.
  select count(*) into n from public.pilot_connect_alerts_due(array['FEED-1']) t;
  assert n = 0, format('a stutter is not a drop, got %s', n);

  perform pg_temp.age_sim_by(interval '5 minutes');
  select count(*) into n from public.pilot_connect_alerts_due(array['FEED-1']) t;
  assert n = 1, format('a sim quiet for ten minutes is a drop, got %s', n);

  select count(*) into n from public.pilot_connect_alerts_due(array['FEED-1']) t;
  assert n = 0, 'and the same flight is never announced twice';

  -- 7. An overflow is delayed, never dropped. Marking a flight told and getting
  --    the push through APNs are two different systems and only the first is
  --    transactional, so the claim has to be bounded by what the caller will
  --    actually deliver on this pass — and the rest have to still be due.
  perform pg_temp.acting_as(carol::text);
  insert into public.pilot_live_status
    (user_id, flight_id, latitude, longitude, altitude_msl, aircraft, callsign)
  values (carol, 'FEED-2', 40.0, -70.0, 33000, 'B738', 'SWA22');

  -- Clearing the claim before ageing, not after: this runs as the table owner,
  -- which RLS does not constrain, and any write that carries a position moves
  -- `sim_live_at` to now. Done the other way round it silently un-drops both
  -- pilots and the assertion below fails for a reason that has nothing to do
  -- with the limit.
  perform pg_temp.acting_as(alice::text);
  update public.pilot_live_status set connect_alert_flight_id = null;

  perform pg_temp.age_sim_by(interval '10 minutes');

  select count(*) into n
    from public.pilot_connect_alerts_due(array['FEED-1', 'FEED-2'], 1) t;
  assert n = 1, format('a limit of one claims one, got %s', n);

  select count(*) into n
    from public.pilot_connect_alerts_due(array['FEED-1', 'FEED-2'], 1) t;
  assert n = 1, format('and the one it did not claim is still due, got %s', n);

  select count(*) into n
    from public.pilot_connect_alerts_due(array['FEED-1', 'FEED-2'], 1) t;
  assert n = 0, format('and then nobody is, got %s', n);

  -- Carol has served her purpose; the rest of this is about alice alone.
  perform pg_temp.acting_as(carol::text);
  perform public.pilot_live_clear();
  perform pg_temp.acting_as(alice::text);

  -- 8. A pilot who has turned the notice off is never a candidate for it.
  perform pg_temp.acting_as(alice::text);
  update public.pilot_live_status set connect_alert_flight_id = null where user_id = alice;
  update public.pilot_profiles set connect_alerts = false where user_id = alice;
  select count(*) into n from public.pilot_connect_alerts_due(array['FEED-1']) t;
  assert n = 0, format('an opted-out pilot is never told, got %s', n);
  update public.pilot_profiles set connect_alerts = true where user_id = alice;

  -- 9. And when the sim comes back it takes the position, and its own clock,
  --    straight back off the server.
  update public.pilot_live_status
     set latitude = 45.0, longitude = -60.0, true_airspeed_knots = 480
   where user_id = alice;
  select * into r from public.pilot_live_status where user_id = alice;
  assert r.position_source = 'connect', 'the sim takes the position back';
  assert r.sim_live_at > now() - interval '1 minute', 'and restarts its own clock';

  -- 10. Nothing accumulated. Hydration refreshes one upserted row and stops the
  --     moment the feed stops carrying the flight; housekeeping is unchanged.
  perform pg_temp.age_by(interval '5 minutes');
  perform public.housekeeping();
  select * into r from public.pilot_live_status where user_id = alice;
  assert r.latitude is null, 'a flight the feed has dropped is cleared as it always was';
  assert r.position_source is null, 'and takes its source with it';
  assert r.fuel_remaining_kg = 61500, 'while the flight itself survives';

  raise notice 'live_status hydration: 27 assertions passed';
end $$;

-- MARK: - Found by the flight id, which is all a map has
--
-- The web tracker holds one identifier for the aeroplane it has drawn -- the
-- live flight id -- and no handle, so `pilot_live_status_for` cannot answer it
-- and `pilot_live_public` does not return the id to join on. What matters
-- about the reader that closes that gap is that it is not a second visibility
-- policy: asking by flight id has to be exactly as revealing as asking by
-- handle, or it is a way around the setting rather than a way into the data.

do $$
declare
  alice uuid := '11111111-1111-1111-1111-111111111111';
  bob   uuid := '22222222-2222-2222-2222-222222222222';
  carol uuid := '33333333-3333-3333-3333-333333333333';
  r record;
  n integer;
begin
  -- A clean table. Everything above this point was about time passing, and the
  -- rows it leaves behind are aged in ways that would confuse what follows.
  delete from public.pilot_live_status;

  perform pg_temp.acting_as(alice::text);
  insert into public.pilot_live_status
    (user_id, flight_id, latitude, longitude, altitude_msl, aircraft, callsign,
     fuel_remaining_kg, gear_state, phase)
  values (alice, 'WEB-1', 51.4775, -0.4614, 37000, 'A350-900', 'BAW117',
          62000, 0, 'cruise');

  perform pg_temp.acting_as(carol::text);
  insert into public.pilot_live_status
    (user_id, flight_id, latitude, longitude, altitude_msl, aircraft, callsign)
  values (carol, 'WEB-2', 40.6, -73.8, 33000, 'B738', 'SWA22');

  -- 1. Signed out, from a map holding an id and nothing else.
  perform pg_temp.acting_as('');
  select * into r from public.pilot_live_flight('WEB-1');
  assert r.handle = 'alice', 'a public flight is found by the id the feed uses';
  assert r.is_live, 'and is live while the position is fresh';
  assert r.latitude = 51.4775, 'at the position the sim reported';
  assert r.position_source = 'connect', 'saying which of the two put it there';
  assert r.fuel_remaining_kg = 62000, 'and carrying what only the sim can see';

  -- 2. The setting is the setting. A stranger with the id gets no more than a
  --    stranger with the handle, which is the whole point of reusing
  --    `pilot_live_readable` rather than writing a second rule here.
  select count(*) into n from public.pilot_live_flight('WEB-2') t;
  assert n = 0, format('followers-only is not public, got %s', n);

  perform pg_temp.acting_as(bob::text);
  select count(*) into n from public.pilot_live_flight('WEB-2') t;
  assert n = 0, format('and bob does not follow carol, got %s', n);

  insert into public.pilot_follows (follower_id, following_id) values (bob, carol);
  select count(*) into n from public.pilot_live_flight('WEB-2') t;
  assert n = 1, format('a follower sees what the follower list would show, got %s', n);

  -- 3. And a pilot can always see her own flight, whatever she broadcasts to.
  perform pg_temp.acting_as(carol::text);
  select * into r from public.pilot_live_flight('WEB-2');
  assert r.handle = 'carol', 'a pilot can always read her own flight';

  -- 4. Nothing is found for an id nobody is flying, and an empty id is not a
  --    wildcard for every row whose `flight_id` was never written.
  perform pg_temp.acting_as('');
  select count(*) into n from public.pilot_live_flight('WEB-404') t;
  assert n = 0, format('an unknown id finds nobody, got %s', n);
  select count(*) into n from public.pilot_live_flight('') t;
  assert n = 0, format('and an empty id is not a wildcard, got %s', n);
  select count(*) into n from public.pilot_live_flight(null) t;
  assert n = 0, format('nor is null, got %s', n);

  -- 5. The freshness split is `pilot_live_status_for`'s, for the same reason:
  --    a position is true for four minutes, while "she was at 62 tonnes" is a
  --    fact about an aeroplane and keeps for the day.
  perform pg_temp.age_by(interval '5 minutes');
  select * into r from public.pilot_live_flight('WEB-1');
  assert r.handle = 'alice', 'a quiet flight is still answered for';
  assert not r.is_live, 'but is not claimed to be live';
  assert r.latitude is null, 'and a stale position is withheld';
  assert r.position_source is null, 'with nothing to attribute';
  assert r.fuel_remaining_kg = 62000, 'while the flight itself survives';
  assert r.gear_state = 0, 'configuration included';
  assert r.sim_live_at is not null, 'dated, so a reader can say how old it is';

  raise notice 'live_status by flight id: 19 assertions passed';
end $$;


rollback;
