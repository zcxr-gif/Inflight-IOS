-- RateMyATC: public stars, private low-star comments, and who receives them.
--
-- Run with `supabase/tests/run.sh`.

\set ON_ERROR_STOP on
\pset pager off

begin;

insert into auth.users (id) values
  ('dddddddd-0000-0000-0000-000000000001'),
  ('dddddddd-0000-0000-0000-000000000002'),
  ('dddddddd-0000-0000-0000-000000000003'),
  ('dddddddd-0000-0000-0000-000000000004');

insert into public.pilot_profiles (user_id, handle, is_public, if_username) values
  ('dddddddd-0000-0000-0000-000000000001', 'rita',   true,  null),
  ('dddddddd-0000-0000-0000-000000000002', 'sam',    false, null),
  ('dddddddd-0000-0000-0000-000000000003', 'ctl_ann', true, 'Approach_Ann');

grant select on public.atc_ratings to postgres;

create or replace function pg_temp.acting_as(p_user text) returns void
language sql as $$ select set_config('request.jwt.claim.sub', coalesce(p_user, ''), false)::void $$;

create or replace function pg_temp.fails(p_sql text, p_msg text) returns void
language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    return;
  end;
  raise exception 'expected failure: %', p_msg;
end $$;

do $$
declare
  r record;
  j jsonb;
  rita uuid := 'dddddddd-0000-0000-0000-000000000001';
  sam  uuid := 'dddddddd-0000-0000-0000-000000000002';
  ann  uuid := 'dddddddd-0000-0000-0000-000000000003';
  imp  uuid := 'dddddddd-0000-0000-0000-000000000004';
  ctrl text := 'b1b2c3d4-0000-4000-8000-00000000beef';
  sess timestamptz := date_trunc('second', now() - interval '40 minutes');
begin
  -- 1. Signed out and junk are refused.
  perform pg_temp.acting_as(null);
  perform pg_temp.fails(format($q$select public.atc_rate(%L, 'Approach_Ann', 'KSFO', 4, %L, 5)$q$, ctrl, sess), 'signed out');
  perform pg_temp.acting_as(rita::text);
  perform pg_temp.fails(format($q$select public.atc_rate(%L, 'Approach_Ann', 'KSFO', 4, %L, 0)$q$, ctrl, sess), '0 stars');
  perform pg_temp.fails(format($q$select public.atc_rate(%L, 'Approach_Ann', 'KSFO', 4, %L, 6)$q$, ctrl, sess), '6 stars');
  perform pg_temp.fails(format($q$select public.atc_rate(%L, 'Approach_Ann', 'KSFO', 4, %L, 2, 'go to www.x.example')$q$, ctrl, sess), 'link');
  perform pg_temp.fails(format($q$select public.atc_rate(%L, 'Approach_Ann', 'KSFO', 4, %L, 2, %L)$q$, ctrl, sess, repeat('a', 281)), 'too long');
  perform pg_temp.fails(format($q$select public.atc_rate(%L, 'Approach_Ann', 'KSFO', 4, %L, 3)$q$, ctrl, now() - interval '3 days'), 'stale');

  -- 2. One rating per session; re-rating updates it.
  perform public.atc_rate(ctrl, 'Approach_Ann', 'ksfo', 4, sess, 2, 'Missed my handoff twice');
  perform public.atc_rate(ctrl, 'Approach_Ann', 'KSFO', 4, sess, 5, 'Great vectors, thank you');
  select * into r from public.atc_ratings where user_id = rita;
  assert r.stars = 5 and r.comment = 'Great vectors, thank you', 're-rating updates the row';
  assert (select count(*) from public.atc_ratings where user_id = rita) = 1, 'one per session';

  perform pg_temp.acting_as(sam::text);
  perform public.atc_rate(ctrl, 'Approach_Ann', 'KSFO', 4, sess, 2, 'Too many go-arounds for spacing');

  -- 3. The controller cannot rate themselves.
  perform pg_temp.acting_as(ann::text);
  perform pg_temp.fails(format($q$select public.atc_rate(%L, 'approach_ann', 'KSFO', 4, %L, 5)$q$, ctrl, sess), 'self rating');

  -- 4. Public: every star counts; only 4-5 star comments are shown, and the
  --    low comment is nowhere in the public payload.
  perform pg_temp.acting_as(null);
  select * into r from public.atc_rating_counts(array[ctrl]);
  assert r.rating_count = 2 and r.rating_avg = 3.5, 'average of all stars is public';
  j := public.atc_rating_profile(ctrl);
  assert (j->>'count')::int = 2 and (j->'dist'->>'2')::int = 1 and (j->'dist'->>'5')::int = 1, 'distribution';
  assert jsonb_array_length(j->'comments') = 1, 'only the 5-star comment is public';
  assert j->'comments'->0->'by'->>'handle' = 'rita', 'public comment names a public rater';
  assert position('go-arounds' in j::text) = 0, 'the low-star comment never appears publicly';

  -- 5. The caller sees their own stars.
  perform pg_temp.acting_as(sam::text);
  select * into r from public.atc_rating_counts(array[ctrl]);
  assert r.my_stars = 2 and r.my_session_started_at = sess, 'my stars';

  -- 6. The uncontested owner of the name gets the private feedback, anonymous.
  perform pg_temp.acting_as(ann::text);
  j := public.atc_kudos_inbox(null);
  assert (j->>'owner')::boolean, 'uncontested claim owns the inbox';
  assert (j->>'rating_count')::int = 2 and (j->>'rating_avg')::numeric = 3.5, 'rating summary';
  assert (j->>'feedback_unseen')::int = 1 and jsonb_array_length(j->'feedback') = 1, 'one private comment';
  assert j->'feedback'->0->>'comment' = 'Too many go-arounds for spacing', 'it is the low-star one';
  assert (j->'feedback'->0) ? 'by' = false and position(sam::text in j::text) = 0, 'and it is anonymous';
  j := public.atc_kudos_inbox(now() + interval '1 minute');
  assert (j->>'feedback_unseen')::int = 0, 'since applies to feedback';

  -- 7. A second account claiming the same name: contested, so nobody gets
  --    private text, though the public summary still shows.
  insert into public.pilot_profiles (user_id, handle, is_public, if_username)
  values (imp, 'not_ann', true, 'APPROACH_ANN');
  perform pg_temp.acting_as(imp::text);
  j := public.atc_kudos_inbox(null);
  assert not (j->>'owner')::boolean and jsonb_array_length(j->'feedback') = 0, 'impersonator gets nothing private';
  perform pg_temp.acting_as(ann::text);
  j := public.atc_kudos_inbox(null);
  assert not (j->>'owner')::boolean and jsonb_array_length(j->'feedback') = 0, 'contested: the real one waits too';

  --    Verifying one claimant settles it.
  perform pg_temp.acting_as(null);   -- only a server sets this, never the pilot
  update public.pilot_profiles set if_username_verified = true where user_id = ann;
  assert (select if_username_verified from public.pilot_profiles where user_id = ann), 'verified flag set';
  perform pg_temp.acting_as(ann::text);
  j := public.atc_kudos_inbox(null);
  assert (j->>'owner')::boolean and jsonb_array_length(j->'feedback') = 1, 'verified claimant gets it back';
  perform pg_temp.acting_as(imp::text);
  j := public.atc_kudos_inbox(null);
  assert jsonb_array_length(j->'feedback') = 0, 'the unverified one still does not';

  -- 8. Hidden ratings vanish from everything.
  update public.atc_ratings set hidden = true where user_id = sam;
  perform pg_temp.acting_as(null);
  select * into r from public.atc_rating_counts(array[ctrl]);
  assert r.rating_count = 1 and r.rating_avg = 5, 'hidden rating does not count';
end $$;

-- 9. The table is closed; readers are open to anon, writers and the inbox are not.
set role anon;
select pg_temp.fails('select * from public.atc_ratings', 'anon table read');
select pg_temp.fails($q$select public.atc_rate('b1b2c3d4-0000', 'x', 'KSFO', 4, now(), 5)$q$, 'anon rate');
select pg_temp.fails('select public.atc_kudos_inbox(null)', 'anon inbox');
select pg_temp.fails('select public.atc_my_controller_name()', 'anon claim helper');
select (public.atc_rating_profile('b1b2c3d4-0000-4000-8000-00000000beef')->>'count')::int >= 0 as anon_can_read_ratings;
reset role;

set role authenticated;
select pg_temp.fails('select * from public.atc_ratings', 'authenticated table read');
select pg_temp.fails('select public.atc_my_controller_name()', 'authenticated claim helper');
reset role;

rollback;

\echo 'atc_ratings: ok'
