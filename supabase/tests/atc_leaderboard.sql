-- RateMyATC board: ranking, minimums, periods and what it never exposes.
--
-- Run with `supabase/tests/run.sh`.

\set ON_ERROR_STOP on
\pset pager off

begin;

-- Twelve raters, so the ratings below can be inserted directly (the RPC's
-- rules are covered in atc_ratings.sql; this file is about the board).
insert into auth.users (id)
select ('eeeeeeee-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid from generate_series(1, 12) i;

do $$
declare
  j jsonb;
  u uuid;
  sess timestamptz := date_trunc('second', now() - interval '1 hour');
  old  timestamptz := now() - interval '90 days';
begin
  -- Ace: ten 5★ ratings. Solo: a single 5★ rating. Steady: five 4★.
  -- Old: three 5★ ratings from 90 days ago. Thanked: kudos only.
  for i in 1..10 loop
    u := ('eeeeeeee-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid;
    insert into public.atc_ratings (user_id, controller_if_id, controller_username, airport_icao, session_started_at, stars, comment)
    values (u, 'ace0000-0000-0000-0001', 'Ace', 'EGLL', sess, 5, case when i = 1 then 'Secret low comment never here' end);
  end loop;
  insert into public.atc_ratings (user_id, controller_if_id, controller_username, session_started_at, stars)
  values ('eeeeeeee-0000-0000-0000-000000000011', 'solo000-0000-0000-0001', 'Solo', sess, 5);
  for i in 1..5 loop
    u := ('eeeeeeee-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid;
    insert into public.atc_ratings (user_id, controller_if_id, controller_username, airport_icao, session_started_at, stars)
    values (u, 'stdy000-0000-0000-0001', 'Steady', 'KSFO', sess, 4);
  end loop;
  for i in 1..3 loop
    u := ('eeeeeeee-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid;
    insert into public.atc_ratings (user_id, controller_if_id, controller_username, session_started_at, stars, created_at)
    values (u, 'oldd000-0000-0000-0001', 'Oldie', old, 5, old);
  end loop;
  for i in 1..4 loop
    u := ('eeeeeeee-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid;
    insert into public.atc_commendations (user_id, controller_if_id, controller_username, airport_icao, session_started_at, kind)
    values (u, 'thnk000-0000-0000-0001', 'Thanked', 'EDDF', sess, case when i % 2 = 0 then 'good_day' else 'thumbs_up' end);
  end loop;

  -- 30 days: Oldie is out, Solo is under the minimum, Ace beats Steady.
  j := public.atc_leaderboard(30, 25);
  assert jsonb_array_length(j->'top_rated') = 2, 'only controllers with 3+ ratings in the period';
  assert j->'top_rated'->0->>'username' = 'Ace' and j->'top_rated'->1->>'username' = 'Steady', 'ranked by bayesian score';
  assert (j->'top_rated'->0->>'rating_count')::int = 10, 'counts';
  assert j->'most_kudos'->0->>'username' = 'Thanked' and (j->'most_kudos'->0->>'kudos')::int = 4, 'most kudos';
  assert (j->'most_kudos'->0->>'thumbs_up')::int = 2 and (j->'most_kudos'->0->>'good_day')::int = 2, 'kudos split';
  assert j->'most_rated'->0->>'username' = 'Ace', 'most rated';
  assert (select count(*) from jsonb_array_elements(j->'most_rated') e where e->>'username' = 'Solo') = 1,
    'a single rating still counts on most_rated';
  assert (j->>'days')::int = 30 and (j->>'ratings')::int = 16, 'period summary';
  assert position('Secret low comment' in j::text) = 0, 'comments never appear on the board';
  assert position('eeeeeeee' in j::text) = 0, 'rater ids never appear on the board';

  -- All time: Oldie joins.
  j := public.atc_leaderboard(0, 25);
  assert (select count(*) from jsonb_array_elements(j->'top_rated') e where e->>'username' = 'Oldie') = 1, 'all time includes old ratings';
  assert j->'days' = 'null'::jsonb, 'all time has no day count';

  -- Hidden and withdrawn rows drop out.
  update public.atc_commendations set withdrawn_at = now() where controller_if_id = 'thnk000-0000-0000-0001';
  j := public.atc_leaderboard(30, 25);
  assert jsonb_array_length(j->'most_kudos') = 0, 'withdrawn kudos do not count';

  -- The limit holds.
  j := public.atc_leaderboard(0, 1);
  assert jsonb_array_length(j->'top_rated') = 1 and jsonb_array_length(j->'most_rated') = 1, 'limit';
end $$;

set role anon;
select jsonb_typeof(public.atc_leaderboard(30, 5)) = 'object' as anon_can_read_board;
reset role;

rollback;

\echo 'atc_leaderboard: ok'
