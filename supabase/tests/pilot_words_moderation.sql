-- Named or anonymous RateMyATC comments, taking words down, the pause that
-- covers words, and the queue staff are told from.
--
-- Run with `supabase/tests/run.sh`.

\set ON_ERROR_STOP on
\pset pager off

begin;

insert into auth.users (id) values
  ('ffffffff-0000-0000-0000-000000000001'),
  ('ffffffff-0000-0000-0000-000000000002'),
  ('ffffffff-0000-0000-0000-000000000003');

insert into public.pilot_profiles (user_id, handle, is_public, if_username, bio) values
  ('ffffffff-0000-0000-0000-000000000001', 'wren',     true, null, 'Heavy metal on the long haul'),
  ('ffffffff-0000-0000-0000-000000000002', 'otto',     true, null, null),
  ('ffffffff-0000-0000-0000-000000000003', 'ctl_cleo', true, 'Ground_Cleo', null);

grant select on public.atc_ratings, public.atc_commendations, public.pilot_content_queue,
  public.pilot_content_actions, public.pilot_warnings to postgres;

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
  j jsonb;
  q record;
  t record;
  n integer;
  wren uuid := 'ffffffff-0000-0000-0000-000000000001';
  otto uuid := 'ffffffff-0000-0000-0000-000000000002';
  cleo uuid := 'ffffffff-0000-0000-0000-000000000003';
  ctrl text := 'a1b2c3d4-0000-4000-8000-0000000c1e00';
  sess timestamptz := date_trunc('second', now() - interval '20 minutes');
  r_wren uuid;
  r_otto uuid;
begin
  -- 1. Profile writes are queued: the bio inserted above, then a new avatar.
  assert exists (select 1 from public.pilot_content_queue where user_id = wren and kind = 'bio'), 'bio queued';
  assert exists (select 1 from public.pilot_content_queue where user_id = wren and kind = 'handle'), 'handle queued';
  update public.pilot_profiles set avatar_path = 'ffffffff-0000-0000-0000-000000000001/a.jpg' where user_id = wren;
  assert exists (select 1 from public.pilot_content_queue
                  where kind = 'avatar' and storage_bucket = 'pilot-avatars'
                    and storage_path = 'ffffffff-0000-0000-0000-000000000001/a.jpg'), 'avatar queued';
  n := (select count(*) from public.pilot_content_queue where user_id = wren);
  update public.pilot_profiles set accent = accent where user_id = wren;
  assert (select count(*) from public.pilot_content_queue where user_id = wren) = n, 'unchanged fields are not queued';

  -- 2. Low stars default to anonymous, high stars to named; either can flip.
  perform pg_temp.acting_as(wren::text);
  r_wren := public.atc_rate(ctrl, 'Ground_Cleo', 'EGLL', 1, sess, 2, 'Taxi instructions were muddled');
  assert (select anonymous from public.atc_ratings where id = r_wren), '2 stars: anonymous by default';
  perform pg_temp.acting_as(otto::text);
  r_otto := public.atc_rate(ctrl, 'Ground_Cleo', 'EGLL', 1, sess, 5, 'Smooth and quick', true);
  assert (select anonymous from public.atc_ratings where id = r_otto), '5 stars: anonymous when asked';

  perform pg_temp.acting_as(null);
  j := public.atc_rating_profile(ctrl);
  assert (j->>'count')::int = 2 and (j->>'avg')::numeric = 3.5, 'both ratings count';
  assert jsonb_array_length(j->'comments') = 1 and (j->'comments'->0->>'anonymous')::boolean
     and not (j->'comments'->0 ? 'by'), 'anonymous public comment has no name';
  j := public.atc_site_stats(30);
  assert not (j->'recent_comments'->0 ? 'by'), 'site stats agree';

  --    Wren signs the private one; the controller sees her name.
  perform pg_temp.acting_as(wren::text);
  perform public.atc_rate(ctrl, 'Ground_Cleo', 'EGLL', 1, sess, 2, 'Taxi instructions were muddled', false);
  perform pg_temp.acting_as(cleo::text);
  j := public.atc_kudos_inbox(null);
  assert jsonb_array_length(j->'feedback') = 1, 'one private comment';
  assert j->'feedback'->0->'by'->>'handle' = 'wren', 'named private feedback names the rater';
  assert not (j->'feedback'->0->>'anonymous')::boolean, 'and says so';

  --    Callers that do not send p_anonymous keep the old default.
  perform pg_temp.acting_as(wren::text);
  perform public.atc_rate(ctrl, 'Ground_Cleo', 'EGLL', 1, sess, 3, 'Taxi instructions were muddled');
  assert (select anonymous from public.atc_ratings where id = r_wren), 'default re-applies on re-rate';

  -- 3. Words are queued once per change, with their context.
  select * into q from public.pilot_content_queue where content_id = r_wren order by id desc limit 1;
  assert q.kind = 'rating_comment' and (q.detail->>'private')::boolean and (q.detail->>'stars')::int = 2,
    'rating comment queued with context';
  assert (select count(*) from public.pilot_content_queue where content_id = r_wren) = 1,
    'changing only stars or the name does not re-queue the same words';

  perform pg_temp.acting_as(otto::text);
  perform public.atc_commend(ctrl, 'Ground_Cleo', 'EGLL', 1, sess, 'good_day', 'Lovely flow today');
  assert exists (select 1 from public.pilot_content_queue where user_id = otto and kind = 'kudos_note'
                    and body = 'Lovely flow today'), 'kudos note queued';

  -- 4. Staff see every comment, anonymous or not, with the author.
  perform pg_temp.acting_as(null);
  assert (select count(*) from public.admin_pilot_comments(200, 0, false)) = 3, 'two comments and a note';
  select * into t from public.admin_pilot_comments(200, 0, false) where id = r_otto;
  assert t.handle = 'otto' and t.anonymous, 'anonymous comment still shows its author to staff';

  -- 5. Taking the words down keeps the stars.
  select * into t from public.admin_pilot_comment_takedown('rating', r_wren, false, 'harassment', 'rude', 'Mod');
  assert (select comment is null and not hidden from public.atc_ratings where id = r_wren), 'words gone, rating stays';
  assert (select content_text from public.pilot_content_actions where id = t.action_id) = 'Taxi instructions were muddled',
    'the record keeps the words';
  assert (public.atc_rating_profile(ctrl)->>'count')::int = 2, 'stars still count';
  perform pg_temp.fails(format($q$select * from public.admin_pilot_comment_takedown('rating', %L)$q$, r_wren), 'twice');

  --    Removing the whole rating takes the stars too, and can pause the pilot.
  select * into t from public.admin_pilot_comment_takedown('rating', r_otto, true, 'spam', null, 'Mod',
                                                           'first', null, true, 7);
  assert (select hidden from public.atc_ratings where id = r_otto), 'whole rating hidden';
  assert (public.atc_rating_profile(ctrl)->>'count')::int = 1, 'and out of the average';
  assert t.warning_id is not null, 'warned';
  assert (select kind from public.pilot_content_actions where id = t.action_id) = 'rating', 'recorded as the rating';
  assert exists (select 1 from public.admin_pilot_actions(10, otto) where content_text = 'Smooth and quick'), 'record shows the words';

  -- 6. A paused pilot cannot post words, but can still rate and give kudos.
  perform pg_temp.acting_as(otto::text);
  perform pg_temp.fails(format($q$select public.atc_rate(%L, 'Ground_Cleo', 'EGLL', 1, %L, 4, 'Back again')$q$,
                               ctrl, sess - interval '1 hour'), 'paused comment');
  perform pg_temp.fails(format($q$select public.atc_commend(%L, 'Ground_Cleo', 'EGLL', 1, %L, 'thumbs_up', 'hi')$q$,
                               ctrl, sess - interval '1 hour'), 'paused note');
  perform public.atc_rate(ctrl, 'Ground_Cleo', 'EGLL', 1, sess - interval '1 hour', 4);
  perform public.atc_commend(ctrl, 'Ground_Cleo', 'EGLL', 1, sess - interval '1 hour', 'thumbs_up');
  assert position('comments' in public.pilot_upload_notice(otto)) > 0, 'the notice mentions comments';

  -- 7. The queue drains by acknowledgement only.
  perform pg_temp.acting_as(null);
  n := (select count(*) from public.admin_pilot_content_queue(100));
  assert n > 0, 'something to announce';
  assert (select count(*) from public.admin_pilot_content_queue(100)) = n, 'reading does not consume';
  perform public.admin_pilot_content_queue_ack(array(select id from public.admin_pilot_content_queue(2)));
  assert (select count(*) from public.admin_pilot_content_queue(100)) = n - 2, 'acked rows are gone from the feed';
  select * into q from public.admin_pilot_content_queue(1);
  assert q.handle is not null, 'queue rows carry the handle';
end $$;

-- 8. Nothing here is open to pilots.
set role authenticated;
select pg_temp.fails('select * from public.pilot_content_queue', 'queue table');
select pg_temp.fails('select * from public.admin_pilot_content_queue(5)', 'queue reader');
select pg_temp.fails('select public.admin_pilot_content_queue_ack(array[1::bigint])', 'queue ack');
select pg_temp.fails('select * from public.admin_pilot_comments()', 'comment list');
select pg_temp.fails($q$select * from public.admin_pilot_comment_takedown('rating', gen_random_uuid())$q$, 'takedown');
reset role;
set role anon;
select pg_temp.fails('select * from public.admin_pilot_comments()', 'anon comment list');
reset role;

rollback;

\echo 'pilot_words_moderation: ok'
