-- The ATC page: controller search for share links, and the page's numbers.
--
-- Run with `supabase/tests/run.sh`.

\set ON_ERROR_STOP on
\pset pager off

begin;

insert into auth.users (id)
select ('ffffffff-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid from generate_series(1, 4) i;

do $$
declare
  j jsonb;
  sess timestamptz := date_trunc('second', now() - interval '1 hour');
begin
  -- Ann renamed: her older rows say Approach_Ann, her newest says Ann_Tower.
  insert into public.atc_ratings (user_id, controller_if_id, controller_username, airport_icao, facility_type, session_started_at, stars, comment, created_at)
  values ('ffffffff-0000-0000-0000-000000000001', 'ann00000-0000-0000-0001', 'Approach_Ann', 'KSFO', 4, sess, 5, 'Lovely vectors', now() - interval '2 hours'),
         ('ffffffff-0000-0000-0000-000000000002', 'ann00000-0000-0000-0001', 'Ann_Tower', 'KSFO', 1, sess, 2, 'Secret low comment', now());
  insert into public.atc_commendations (user_id, controller_if_id, controller_username, airport_icao, facility_type, session_started_at, kind, note)
  values ('ffffffff-0000-0000-0000-000000000003', 'ann00000-0000-0000-0001', 'Ann_Tower', 'KSFO', 1, sess, 'good_day', 'Thanks for opening SFO'),
         ('ffffffff-0000-0000-0000-000000000003', 'bob00000-0000-0000-0001', 'Bob', 'EGLL', 0, sess, 'thumbs_up', null),
         ('ffffffff-0000-0000-0000-000000000004', 'anni0000-0000-0000-0001', 'Annie', 'EDDF', 1, sess, 'thumbs_up', null);

  -- 1. Search: exact first, then prefixes (busiest first), then contains;
  --    a controller is listed once, under their newest name.
  j := public.atc_controller_search('ann_tower', 10);
  assert j->0->>'controller_if_id' = 'ann00000-0000-0000-0001' and j->0->>'username' = 'Ann_Tower', 'exact match first';
  assert (j->0->>'rating_count')::int = 2 and (j->0->>'kudos')::int = 1, 'counts on the hit';
  j := public.atc_controller_search('ann', 10);
  assert jsonb_array_length(j) = 2 and j->0->>'username' = 'Ann_Tower' and j->1->>'username' = 'Annie', 'prefixes, busiest first';
  j := public.atc_controller_search('tower', 10);
  assert jsonb_array_length(j) = 1 and j->0->>'username' = 'Ann_Tower', 'contains';
  assert jsonb_array_length(public.atc_controller_search('approach_ann', 10)) = 0, 'listed under the newest name only';
  j := public.atc_controller_search('ann00000-0000-0000-0001', 10);
  assert j->0->>'controller_if_id' = 'ann00000-0000-0000-0001', 'id lookup';
  assert jsonb_array_length(public.atc_controller_search('a', 10)) = 0, 'one character finds nothing';
  assert jsonb_array_length(public.atc_controller_search('%', 10)) = 0, 'wildcards are literal';
  assert position('Secret low comment' in public.atc_controller_search('ann', 10)::text) = 0, 'no comments in search';

  -- 2. Stats: totals, places, positions, and only public words.
  j := public.atc_site_stats(30);
  assert (j->>'ratings')::int = 2 and (j->>'kudos')::int = 3 and (j->>'controllers')::int = 3, 'totals';
  assert (j->>'pilots')::int = 4 and (j->>'notes')::int = 1, 'pilots and notes';
  assert j->'airports'->0->>'icao' = 'KSFO' and (j->'airports'->0->>'ratings')::int = 2, 'busiest airport';
  assert jsonb_array_length(j->'daily') = 30, 'thirty days';
  assert (j->'daily'->29->>'kudos')::int = 3, 'today counted';
  assert jsonb_array_length(j->'recent_comments') = 1 and j->'recent_comments'->0->>'comment' = 'Lovely vectors', 'only 4-5 star comments';
  assert position('Secret low comment' in j::text) = 0, 'low comments never on the page';
  assert position('ffffffff' in j::text) = 0, 'no rater ids';
  assert j->'recent_notes'->0->>'note' = 'Thanks for opening SFO', 'public notes';

  -- Withdrawn and hidden rows drop out.
  update public.atc_commendations set withdrawn_at = now() where controller_if_id = 'ann00000-0000-0000-0001';
  update public.atc_ratings set hidden = true where comment = 'Lovely vectors';
  j := public.atc_site_stats(0);
  assert (j->>'kudos')::int = 2 and jsonb_array_length(j->'recent_notes') = 0, 'withdrawn kudos gone';
  assert jsonb_array_length(j->'recent_comments') = 0 and (j->>'ratings')::int = 1, 'hidden rating gone';
  assert j->'days' = 'null'::jsonb, 'all time';
end $$;

set role anon;
select jsonb_typeof(public.atc_site_stats(30)) = 'object' as anon_reads_stats,
       jsonb_typeof(public.atc_controller_search('bob', 5)) = 'array' as anon_searches;
reset role;

rollback;

\echo 'atc_page: ok'
