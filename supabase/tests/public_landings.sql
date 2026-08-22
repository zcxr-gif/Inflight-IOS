-- Who sees a landing, and in what order.
--
-- Two rules here are invisible in the schema and both are the kind that only
-- shows up in production: a feed ordered by the wrong clock buries the rows it
-- exists to show, and a feed that reuses the by-handle visibility rule quietly
-- surfaces followers-only logbooks to a firehose.
--
-- Run with `supabase/tests/run.sh`.

\set ON_ERROR_STOP on
\pset pager off

begin;

insert into auth.users (id) values
  ('bbbbbbbb-0000-0000-0000-000000000001'),
  ('bbbbbbbb-0000-0000-0000-000000000002'),
  ('bbbbbbbb-0000-0000-0000-000000000003');

insert into public.pilot_profiles (user_id, handle, logbook_visibility) values
  ('bbbbbbbb-0000-0000-0000-000000000001', 'pat',  'public'),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'quin', 'followers'),
  ('bbbbbbbb-0000-0000-0000-000000000003', 'rex',  'private');

-- Quin follows nobody; Pat follows Quin, so a follower exists for the
-- followers-only case below.
insert into public.pilot_follows (follower_id, following_id) values
  ('bbbbbbbb-0000-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-000000000002');

create or replace function pg_temp.acting_as(p_user text) returns void
language sql as $$ select set_config('request.jwt.claim.sub', p_user, false)::void $$;

do $$
declare
  n integer;
  r record;
  pat  uuid := 'bbbbbbbb-0000-0000-0000-000000000001';
  quin uuid := 'bbbbbbbb-0000-0000-0000-000000000002';
  rex  uuid := 'bbbbbbbb-0000-0000-0000-000000000003';
begin
  -- 1. A flight with no landing is not a landing, and gets no clock.
  insert into public.pilot_logbook (user_id, flight_id, callsign, aircraft, landed_at)
  values (pat, 'f-pat-1', 'BAW1', 'A350-900', now() - interval '3 hours');

  select landing_recorded_at into r from public.pilot_logbook where flight_id = 'f-pat-1';
  assert r.landing_recorded_at is null, 'a flight without a landing is not stamped';

  select count(*) into n from public.pilot_recent_landings();
  assert n = 0, 'and it is not in the feed';

  -- 2. Attaching one stamps it, and the stamp is now rather than the landing
  --    time -- which is the entire point on a phone.
  update public.pilot_logbook
     set landing_vertical_speed_fpm = -142
   where flight_id = 'f-pat-1';

  select * into r from public.pilot_logbook where flight_id = 'f-pat-1';
  assert r.landing_recorded_at is not null, 'attaching a landing stamps it';
  assert r.landing_recorded_at > r.landed_at + interval '2 hours',
    'the stamp is when we found out, not when the aeroplane touched down';

  -- 3. Editing anything else must not move it back to the top.
  declare
    v_before timestamptz;
  begin
    select landing_recorded_at into v_before from public.pilot_logbook where flight_id = 'f-pat-1';
    update public.pilot_logbook set landing_score = 91 where flight_id = 'f-pat-1';
    select * into r from public.pilot_logbook where flight_id = 'f-pat-1';
    assert r.landing_recorded_at = v_before, 'a later edit does not restamp the landing';
  end;

  -- 4. A public logbook reaches a signed-out reader.
  perform set_config('request.jwt.claim.sub', '', true);
  select count(*) into n from public.pilot_recent_landings();
  assert n = 1, format('a public landing is readable signed out, got %s', n);

  select * into r from public.pilot_recent_landings();
  assert r.handle = 'pat', 'and carries the handle';
  assert r.vertical_speed_fpm = -142, 'and the rate';
  assert r.is_self = false, 'nobody is themselves when nobody is signed in';

  -- 5. Followers-only stays out of the feed even for a follower. This is the
  --    rule that differs from `pilot_logbook_readable`, and the reason it
  --    differs: a firehose is discovery, not lookup.
  insert into public.pilot_logbook
    (user_id, flight_id, callsign, landed_at, landing_vertical_speed_fpm)
  values (quin, 'f-quin-1', 'SHT2', now(), -180);

  perform pg_temp.acting_as(pat::text);
  select count(*) into n from public.pilot_recent_landings() where handle = 'quin';
  assert n = 0, 'a followers-only logbook is not in the public feed, even for a follower';

  -- ...and the pilot still sees their own.
  perform pg_temp.acting_as(quin::text);
  select count(*) into n from public.pilot_recent_landings() where handle = 'quin';
  assert n = 1, 'a pilot always sees their own landing arrive';

  select * into r from public.pilot_recent_landings() where handle = 'quin';
  assert r.is_self, 'and is marked as themselves';

  -- 6. Private is private.
  insert into public.pilot_logbook
    (user_id, flight_id, landed_at, landing_vertical_speed_fpm)
  values (rex, 'f-rex-1', now(), -95);

  perform set_config('request.jwt.claim.sub', '', true);
  select count(*) into n from public.pilot_recent_landings() where handle = 'rex';
  assert n = 0, 'a private logbook is not in the feed';

  -- 7. Newest measurement first, whatever the landing times were.
  --
  -- Both rows were stamped by the trigger from `now()`, which inside one
  -- transaction is a single instant -- so they are tied here in a way they
  -- never are in production, where each landing arrives in its own
  -- transaction. Backdating one is what makes the ordering testable at all.
  update public.pilot_profiles set logbook_visibility = 'public' where handle = 'quin';

  alter table public.pilot_logbook disable trigger pilot_logbook_stamp_landing;
  update public.pilot_logbook
     set landing_recorded_at = landing_recorded_at - interval '1 hour'
   where flight_id = 'f-pat-1';
  alter table public.pilot_logbook enable trigger pilot_logbook_stamp_landing;

  perform set_config('request.jwt.claim.sub', '', true);
  select * into r from public.pilot_recent_landings() limit 1;
  assert r.handle = 'quin', format('the most recently measured landing leads, got %s', r.handle);

  select * into r from public.pilot_recent_landings() where handle = 'pat';
  assert r.landed_at is not null, 'and the older one is still there, with its own clock';

  raise notice 'public landings: 13 assertions passed';
end $$;

rollback;
