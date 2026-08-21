-- Who the own-flight announcer is allowed to reach.
--
-- One rule here decides whether a stranger's phone buzzes about somebody else's
-- flight, and it is invisible in the schema: `if_username` is a claim, not an
-- identity, and two accounts can make the same one. Asserted rather than
-- eyeballed for the same reason as everything in live_status.sql.
--
-- Run with `supabase/tests/run.sh`.

\set ON_ERROR_STOP on
\pset pager off

begin;

insert into auth.users (id) values
  ('aaaaaaaa-0000-0000-0000-000000000001'),
  ('aaaaaaaa-0000-0000-0000-000000000002'),
  ('aaaaaaaa-0000-0000-0000-000000000003'),
  ('aaaaaaaa-0000-0000-0000-000000000004'),
  ('aaaaaaaa-0000-0000-0000-000000000005');

insert into public.pilot_profiles (user_id, handle, if_username, if_username_verified) values
  -- Uncontested, alerts left at their default.
  ('aaaaaaaa-0000-0000-0000-000000000001', 'alice', 'AliceFlies',  false),
  -- Uncontested, but has turned alerts off.
  ('aaaaaaaa-0000-0000-0000-000000000002', 'bob',   'BobAviates',  false),
  -- Two accounts claiming one name, neither checked.
  ('aaaaaaaa-0000-0000-0000-000000000003', 'carol', 'Contested',   false),
  ('aaaaaaaa-0000-0000-0000-000000000004', 'dave',  'contested',   false),
  -- No handle from the sim at all: nothing to join a feed row to.
  ('aaaaaaaa-0000-0000-0000-000000000005', 'erin',  null,          false);

update public.pilot_profiles set flight_alerts = false where handle = 'bob';

do $$
declare
  n integer;
  r record;
begin
  -- 1. The default is on, and the join is lowercased: the feed spells a handle
  --    however the pilot typed it into Infinite Flight.
  select count(*) into n from public.pilot_flight_alert_targets()
   where if_username = 'aliceflies';
  assert n = 1, 'an uncontested pilot with alerts on is a target';

  select * into r from public.pilot_flight_alert_targets() where if_username = 'aliceflies';
  assert r.handle = 'alice', 'the target carries the handle';
  assert r.user_id = 'aaaaaaaa-0000-0000-0000-000000000001',
    'the target carries the account the push is addressed to';

  -- 2. Off means off, server-side, not merely unsubscribed in the app.
  select count(*) into n from public.pilot_flight_alert_targets()
   where if_username = 'bobaviates';
  assert n = 0, 'flight_alerts = false is honoured here, not in the client';

  -- 3. The one that matters. Two accounts claim one name and neither has been
  --    checked, so neither is told: being told about a stranger's flight is
  --    worse than not being told about your own.
  select count(*) into n from public.pilot_flight_alert_targets()
   where if_username = 'contested';
  assert n = 0, format('a contested handle reaches nobody, got %s targets', n);

  -- 4. Verifying one of them settles it, and settles it for that account only.
  update public.pilot_profiles
     set if_username_verified = true
   where handle = 'carol';

  select count(*) into n from public.pilot_flight_alert_targets()
   where if_username = 'contested';
  assert n = 1, format('a verified claimant wins the contested handle, got %s', n);

  select * into r from public.pilot_flight_alert_targets() where if_username = 'contested';
  assert r.handle = 'carol', 'and it is the verified one who is told';

  -- 5. A profile with no Infinite Flight handle has nothing to join to and is
  --    not a target, rather than being a target matching every flight with a
  --    null username.
  select count(*) into n from public.pilot_flight_alert_targets() where if_username is null;
  assert n = 0, 'a profile with no sim handle is not a target';

  raise notice 'own-flight alert targets: 8 assertions passed';
end $$;

rollback;
