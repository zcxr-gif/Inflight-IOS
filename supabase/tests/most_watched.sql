-- Who appears on the most-watched board, and in what order.
--
-- A leaderboard is the one screen that goes looking for people the reader never
-- asked about, so the interesting assertions here are all denials: a private
-- profile must not be ranked, a block must remove the blocker from the blocked
-- reader's board, and "flying now" must mean flying *as far as this reader is
-- allowed to know* rather than flying at all. The last one is the leak worth
-- having a test for -- a followers-only live status turned into a public online
-- indicator looks exactly like a working feature.
--
-- Run with `supabase/tests/run.sh`.

\set ON_ERROR_STOP on
\pset pager off

begin;

insert into auth.users (id) values
  ('dddddddd-0000-0000-0000-000000000001'),
  ('dddddddd-0000-0000-0000-000000000002'),
  ('dddddddd-0000-0000-0000-000000000003'),
  ('dddddddd-0000-0000-0000-000000000004'),
  ('dddddddd-0000-0000-0000-000000000005'),
  ('dddddddd-0000-0000-0000-000000000006'),
  ('dddddddd-0000-0000-0000-000000000007');

-- Nina is the star, Omar is second, Priya is new and climbing fast, Quentin
-- goes private further down, and the last three are nothing but followers.
--
-- Quentin starts public because `pilot_follows_guard` refuses a follow of a
-- private profile: the state being tested -- a well-followed account that has
-- since been hidden -- can only be reached the way a real one reaches it, by
-- collecting the followers first and then pulling the profile down.
insert into public.pilot_profiles (user_id, handle, is_public, live_visibility) values
  ('dddddddd-0000-0000-0000-000000000001', 'nina',    true,  'followers'),
  ('dddddddd-0000-0000-0000-000000000002', 'omar',    true,  'public'),
  ('dddddddd-0000-0000-0000-000000000003', 'priya',   true,  'public'),
  ('dddddddd-0000-0000-0000-000000000004', 'quentin', true,  'public'),
  ('dddddddd-0000-0000-0000-000000000005', 'ravi',    true,  'public'),
  ('dddddddd-0000-0000-0000-000000000006', 'sofia',   true,  'public'),
  ('dddddddd-0000-0000-0000-000000000007', 'tomas',   true,  'public');

create or replace function pg_temp.acting_as(p_user text) returns void
language sql as $$ select set_config('request.jwt.claim.sub', p_user, false)::void $$;

do $$
declare
  n integer;
  r record;
  nina    uuid := 'dddddddd-0000-0000-0000-000000000001';
  omar    uuid := 'dddddddd-0000-0000-0000-000000000002';
  priya   uuid := 'dddddddd-0000-0000-0000-000000000003';
  quentin uuid := 'dddddddd-0000-0000-0000-000000000004';
  ravi    uuid := 'dddddddd-0000-0000-0000-000000000005';
  sofia   uuid := 'dddddddd-0000-0000-0000-000000000006';
  tomas   uuid := 'dddddddd-0000-0000-0000-000000000007';
begin
  -- Nina: three followers, all of them old news.
  insert into public.pilot_follows (follower_id, following_id, created_at) values
    (ravi,  nina, now() - interval '200 days'),
    (sofia, nina, now() - interval '190 days'),
    (tomas, nina, now() - interval '180 days');

  -- Omar: two, also old.
  insert into public.pilot_follows (follower_id, following_id, created_at) values
    (ravi,  omar, now() - interval '150 days'),
    (sofia, omar, now() - interval '140 days');

  -- Priya: two, both this week.
  insert into public.pilot_follows (follower_id, following_id, created_at) values
    (sofia, priya, now() - interval '2 days'),
    (tomas, priya, now() - interval '1 day');

  -- Quentin is followed as much as anybody, and then goes private. The follows
  -- survive -- hiding a profile is not the same as severing them, which only a
  -- block does -- so the row is still there to be wrongly ranked.
  insert into public.pilot_follows (follower_id, following_id, created_at) values
    (ravi,  quentin, now() - interval '100 days'),
    (sofia, quentin, now() - interval '90 days'),
    (tomas, quentin, now() - interval '80 days');

  update public.pilot_profiles set is_public = false where handle = 'quentin';

  select count(*) into n from public.pilot_follows f where f.following_id = quentin;
  assert n = 3, 'going private keeps the followers, got ' || n;

  -- 1. All time is ordered by the total, and a pilot with no followers at all
  --    is absent rather than present with a nought.
  select count(*) into n from public.pilot_most_watched('all', 7, 10);
  assert n = 3, 'only the three visible pilots with followers are ranked, got ' || n;

  select * into r from public.pilot_most_watched('all', 7, 10) limit 1;
  assert r.handle = 'nina', 'the most followed pilot leads the all-time board';
  assert r.follower_count = 3, 'and carries her real count';
  assert r.new_followers = 0, 'none of which arrived this week';

  -- 2. A private profile is not ranked, however many followers it has. This is
  --    the assertion that stops the board becoming a way to enumerate hidden
  --    accounts by their popularity.
  select count(*) into n
    from public.pilot_most_watched('all', 7, 10) b
   where b.handle = 'quentin';
  assert n = 0, 'a private profile is never ranked';

  -- 3. Rising re-orders by the window, not the total: Priya beats Nina on two
  --    followers against three, and everybody with nothing new drops off.
  select * into r from public.pilot_most_watched('rising', 7, 10) limit 1;
  assert r.handle = 'priya', 'the rising board leads with the fastest climber';

  select count(*) into n from public.pilot_most_watched('rising', 7, 10);
  assert n = 1, 'and nobody with no new followers is on it, got ' || n;

  -- 4. Widen the window and the old follows count again, which puts the
  --    all-time leader back on top.
  select * into r from public.pilot_most_watched('rising', 365, 10) limit 1;
  assert r.handle = 'nina', 'a window wide enough to hold the old follows re-ranks them';

  -- 5. Nobody is flying yet, so the flying board is empty and every row on the
  --    other boards says so.
  select count(*) into n from public.pilot_most_watched('flying', 7, 10);
  assert n = 0, 'nobody is reporting, so nobody is flying';

  select count(*) into n
    from public.pilot_most_watched('all', 7, 10) b
   where b.is_flying;
  assert n = 0, 'and no row claims to be';

  -- 6. Two pilots start reporting. Omar broadcasts publicly; Nina broadcasts to
  --    her followers only.
  insert into public.pilot_live_status (user_id, flight_id, callsign, latitude, longitude, last_live_at)
  values (omar, 'f-omar-1', 'UAE1', 25.2, 55.3, now()),
         (nina, 'f-nina-1', 'BAW9', 51.4, -0.4, now());

  -- A signed-out reader sees the public one and only the public one.
  perform pg_temp.acting_as('');

  select count(*) into n from public.pilot_most_watched('flying', 7, 10);
  assert n = 1, 'a signed-out reader sees only the public live status, got ' || n;

  select * into r from public.pilot_most_watched('flying', 7, 10) limit 1;
  assert r.handle = 'omar', 'and it is the pilot who chose public';
  assert not r.viewer_follows, 'a signed-out reader follows nobody';
  assert not r.is_self, 'and is nobody';

  select * into r
    from public.pilot_most_watched('all', 7, 10) b
   where b.handle = 'nina';
  assert not r.is_flying,
    'a followers-only live status is not an online indicator for a stranger';

  -- 7. One of Nina's own followers sees her flying, because that is what
  --    followers-only means.
  perform pg_temp.acting_as(ravi::text);

  select * into r
    from public.pilot_most_watched('all', 7, 10) b
   where b.handle = 'nina';
  assert r.is_flying, 'a follower may see a followers-only live status';
  assert r.viewer_follows, 'and is told they follow her';

  select count(*) into n from public.pilot_most_watched('flying', 7, 10);
  assert n = 2, 'so the flying board has both pilots for them, got ' || n;

  -- 8. A block removes the blocker from the blocked reader's board entirely --
  --    not just her live status.
  insert into public.pilot_blocks (blocker_id, blocked_id) values (nina, ravi);

  select count(*) into n
    from public.pilot_most_watched('all', 7, 10) b
   where b.handle = 'nina';
  assert n = 0, 'a blocked reader cannot see the blocker on the board';

  -- ...and everybody else still can.
  perform pg_temp.acting_as(sofia::text);
  select count(*) into n
    from public.pilot_most_watched('all', 7, 10) b
   where b.handle = 'nina';
  assert n = 1, 'the block is about one reader, not about the board';

  -- 9. A pilot reading their own board is told which row is theirs.
  perform pg_temp.acting_as(priya::text);
  select * into r
    from public.pilot_most_watched('all', 7, 10) b
   where b.handle = 'priya';
  assert r.is_self, 'a pilot recognises themselves on the board';
  assert not r.viewer_follows, 'and does not follow themselves';

  -- 10. An unknown scope from a client one version ahead falls back to the
  --     whole board rather than failing or returning nothing.
  select count(*) into n from public.pilot_most_watched('sideways', 7, 10);
  assert n = 3, 'an unrecognised scope is the all-time board, got ' || n;

  -- 11. The limit is clamped at both ends rather than trusted.
  select count(*) into n from public.pilot_most_watched('all', 7, 0);
  assert n = 1, 'a limit under one is one, got ' || n;

  select count(*) into n from public.pilot_most_watched('all', 7, 10000);
  assert n = 3, 'and an absurd one is capped without erroring, got ' || n;

  raise notice 'most watched: 26 assertions passed';
end $$;

rollback;
