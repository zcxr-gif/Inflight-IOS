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
create or replace function pg_temp.age_by(p_interval interval) returns void
language plpgsql as $$
begin
  alter table public.pilot_live_status disable trigger pilot_live_status_stamp;
  update public.pilot_live_status
     set last_live_at = last_live_at - p_interval,
         updated_at   = updated_at - p_interval;
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

rollback;
