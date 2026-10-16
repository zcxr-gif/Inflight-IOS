-- ATC commendations: who may leave one, how many, and what readers see.
--
-- Run with `supabase/tests/run.sh`.

\set ON_ERROR_STOP on
\pset pager off

begin;

insert into auth.users (id) values
  ('cccccccc-0000-0000-0000-000000000001'),
  ('cccccccc-0000-0000-0000-000000000002'),
  ('cccccccc-0000-0000-0000-000000000003');

insert into public.pilot_profiles (user_id, handle, is_public, if_username) values
  ('cccccccc-0000-0000-0000-000000000001', 'ada',  true,  'Ada_Pilot'),
  ('cccccccc-0000-0000-0000-000000000002', 'bobby', false, 'Bo'),
  ('cccccccc-0000-0000-0000-000000000003', 'ctrl', true,  'Tower_Tom');

grant select on public.atc_commendations to postgres;

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
  n integer;
  r record;
  j jsonb;
  ada uuid := 'cccccccc-0000-0000-0000-000000000001';
  bo  uuid := 'cccccccc-0000-0000-0000-000000000002';
  ctrl_id text := 'a1b2c3d4-0000-4000-8000-00000000abcd';
  sess timestamptz := date_trunc('second', now() - interval '1 hour');
begin
  -- 1. Signed out, nothing is written.
  perform pg_temp.acting_as(null);
  perform pg_temp.fails(format(
    $q$select public.atc_commend(%L, 'Tower_Tom', 'EGLL', 1, %L, 'thumbs_up')$q$, ctrl_id, sess),
    'signed-out commend');

  -- 2. Signed in, one per session; a second press changes the kind.
  perform pg_temp.acting_as(ada::text);
  perform public.atc_commend(ctrl_id, 'Tower_Tom', 'egll', 1, sess, 'thumbs_up', '  Great flow   today ');
  perform public.atc_commend(ctrl_id, 'Tower_Tom', 'EGLL', 1, sess, 'good_day', 'Great flow today');
  select count(*) into n from public.atc_commendations where user_id = ada;
  assert n = 1, 'one commendation per pilot per controller session';
  select * into r from public.atc_commendations where user_id = ada;
  assert r.kind = 'good_day', 'the second press updates the kind';
  assert r.airport_icao = 'EGLL', 'icao is upper-cased';
  assert r.note = 'Great flow today', 'note whitespace is collapsed';

  -- 3. Junk is refused.
  perform pg_temp.fails(format(
    $q$select public.atc_commend(%L, 'Tower_Tom', 'EGLL', 1, %L, 'thumbs_down')$q$, ctrl_id, sess),
    'unknown kind');
  perform pg_temp.fails(format(
    $q$select public.atc_commend(%L, 'Tower_Tom', 'EGLL', 1, %L, 'thumbs_up')$q$, ctrl_id, now() - interval '5 days'),
    'stale session');
  perform pg_temp.fails(format(
    $q$select public.atc_commend(%L, 'Tower_Tom', 'EGLL', 1, %L, 'thumbs_up', 'see www.spam.example')$q$, ctrl_id, sess - interval '1 minute'),
    'links in a note');
  perform pg_temp.fails(format(
    $q$select public.atc_commend(%L, 'Tower_Tom', 'EGLL', 1, %L, 'thumbs_up', 'nsfw stuff')$q$, ctrl_id, sess - interval '1 minute'),
    'filtered words in a note');
  perform pg_temp.fails(format(
    $q$select public.atc_commend(%L, 'Tower_Tom', 'EGLL', 1, %L, 'thumbs_up', %L)$q$, ctrl_id, sess - interval '1 minute', repeat('a', 141)),
    'note over 140');

  -- 4. You cannot commend yourself.
  perform pg_temp.fails(format(
    $q$select public.atc_commend(%L, 'ada_pilot', 'KJFK', 1, %L, 'thumbs_up')$q$, 'ffffffff-0000-4000-8000-000000000001', sess),
    'self commendation');

  -- 5. A private pilot counts but is not named.
  perform pg_temp.acting_as(bo::text);
  perform public.atc_commend(ctrl_id, 'Tower_Tom', 'EGLL', 1, sess, 'thumbs_up');

  select * into r from public.atc_commendation_counts(array[ctrl_id, 'nobody-0000-0000']) where controller_if_id = ctrl_id;
  assert r.total = 2 and r.thumbs_up = 1 and r.good_day = 1, 'counts split by kind';
  assert r.my_kind = 'thumbs_up' and r.my_session_started_at = sess, 'the caller sees their own press';

  select * into r from public.atc_commendation_counts(array['nobody-0000-0000']);
  assert r.total = 0 and r.my_kind is null, 'an unknown controller has zero and no press';

  j := public.atc_commendation_profile(ctrl_id);
  assert (j->>'total')::int = 2, 'profile total';
  assert (j->>'sessions')::int = 1, 'profile sessions';
  assert j->'airports'->0->>'icao' = 'EGLL', 'profile airports';
  assert jsonb_array_length(j->'recent') = 2, 'profile recent';
  assert (select count(*) from jsonb_array_elements(j->'recent') e where e->'by'->>'handle' = 'ada') = 1,
    'a public pilot is named';
  assert (select count(*) from jsonb_array_elements(j->'recent') e where e->'by' = '{}'::jsonb) = 1,
    'a private pilot is not';
  assert not (j::text like '%' || bo::text || '%') and not (j::text like '%' || ada::text || '%'),
    'no account ids leak';

  j := public.atc_commendations_for_airport('egll');
  assert (j->>'total')::int = 2 and jsonb_array_length(j->'recent') = 2, 'airport feed';

  -- 6. Hidden rows vanish from every reader.
  update public.atc_commendations set hidden = true where user_id = bo;
  j := public.atc_commendation_profile(ctrl_id);
  assert (j->>'total')::int = 1, 'hidden rows do not count';

  -- 7. Withdrawing hides your own row from every reader and from the
  --    pressed state; pressing again brings it back.
  perform pg_temp.acting_as(ada::text);
  assert public.atc_commendation_withdraw(ctrl_id, sess), 'withdraw own';
  assert not public.atc_commendation_withdraw(ctrl_id, sess), 'nothing left to withdraw';
  j := public.atc_commendation_profile(ctrl_id);
  assert (j->>'total')::int = 0, 'withdrawn and hidden rows do not count';
  select * into r from public.atc_commendation_counts(array[ctrl_id]);
  assert r.total = 0 and r.my_kind is null, 'a withdrawn press is not shown as pressed';
  perform public.atc_commend(ctrl_id, 'Tower_Tom', 'EGLL', 1, sess, 'thumbs_up');
  select * into r from public.atc_commendation_counts(array[ctrl_id]);
  assert r.total = 1 and r.my_kind = 'thumbs_up', 'pressing again restores it';
  select count(*) into n from public.atc_commendations where user_id = bo and hidden;
  assert n = 1, 'bo''s row is untouched';

  -- 7b. The controller's inbox: matched on the IF username of the caller's
  --     own profile, excluding anything they left themselves.
  perform pg_temp.acting_as('cccccccc-0000-0000-0000-000000000003');
  j := public.atc_kudos_inbox(null);
  assert (j->>'linked')::boolean and j->>'username' = 'tower_tom', 'inbox knows who I am';
  assert (j->>'total')::int = 1 and (j->>'unseen')::int = 1, 'one visible kudos for Tower_Tom';
  assert j->'recent'->0->'by'->>'handle' = 'ada', 'and who it came from';
  assert j->>'controller_if_id' = ctrl_id, 'with my IF id to open my profile';
  j := public.atc_kudos_inbox(now() + interval '1 minute');
  assert (j->>'unseen')::int = 0 and jsonb_array_length(j->'recent') = 0, 'nothing newer than since';
  perform pg_temp.acting_as(bo::text);
  j := public.atc_kudos_inbox(null);
  assert (j->>'total')::int = 0, 'another pilot sees nothing in their own inbox';
  perform pg_temp.acting_as(ada::text);

  -- 8. Rate limit: 40 a day (ada already has one), but re-pressing an
  --    existing one still works.
  for i in 1..39 loop
    perform public.atc_commend(format('ratelimit-%s-0000', i), 'X', 'KSFO', 1, sess, 'thumbs_up');
  end loop;
  perform pg_temp.fails(format(
    $q$select public.atc_commend('ratelimit-41-0000', 'X', 'KSFO', 1, %L, 'thumbs_up')$q$, sess),
    'daily cap');
  perform public.atc_commend('ratelimit-1-0000', 'X', 'KSFO', 1, sess, 'good_day');
end $$;

-- 9. The table itself is closed to clients; the readers are open to anon.
set role anon;
select pg_temp.fails('select * from public.atc_commendations', 'anon table read');
select pg_temp.fails($q$select public.atc_commend('a1b2c3d4-0000', 'x', 'EGLL', 1, now(), 'thumbs_up')$q$, 'anon commend');
select public.atc_commendation_profile('a1b2c3d4-0000-4000-8000-00000000abcd') is not null as anon_can_read_profile;
select pg_temp.fails('select public.atc_kudos_inbox(null)', 'anon inbox');
reset role;

set role authenticated;
select pg_temp.fails('select * from public.atc_commendations', 'authenticated table read');
reset role;

rollback;

\echo 'atc_commendations: ok'
