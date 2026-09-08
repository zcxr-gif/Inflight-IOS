-- Taking a picture down, warning the pilot, and stopping the next one.
--
-- Almost nothing worth asserting here is visible in the migration's diff. The
-- shape is two ordinary tables; the behaviour is a set of rules about who may
-- write what, which of several warnings actually holds, and what a pilot is
-- allowed to learn about somebody else. Specifically:
--
--   * a pilot cannot warn themselves, un-restrict themselves, or read anybody
--     else's warnings — the whole access model is "said TO the pilot", and it
--     is enforced by there being no write policy rather than by a check
--     somebody could forget;
--   * the restriction that holds is the LONGEST-lasting one, not the newest,
--     because otherwise a pilot with two blocks starts uploading again the
--     moment the lighter one lapses;
--   * rescinding a warning lifts its block, and lifting a block leaves the
--     warning standing — two different acts that a single switch would
--     conflate;
--   * a takedown records WHICH picture it removed, which the obvious
--     `update ... returning` cannot do (RETURNING gives the new row, whose
--     path is null) — a bug that would leave the record's one identifying
--     field empty on every row;
--   * clearing a banner works for a pilot whose Pro has lapsed, because the
--     write guard's Pro check must not apply to moderation.
--
-- Run with `supabase/tests/run.sh`.

\set ON_ERROR_STOP off
\pset pager off

insert into auth.users (id, email) values
  ('11111111-2222-3333-4444-555555555551', 'mod-alice@example.com'),
  ('11111111-2222-3333-4444-555555555552', 'mod-bob@example.com');

-- Alice claims a handle and puts a picture on it, as the app would.
set request.jwt.claim.sub = '11111111-2222-3333-4444-555555555551';
set role authenticated;
insert into public.pilot_profiles (user_id, handle, display_name)
  values ('11111111-2222-3333-4444-555555555551', 'alice', 'Alice');

set request.jwt.claim.sub = '11111111-2222-3333-4444-555555555552';
insert into public.pilot_profiles (user_id, handle, display_name)
  values ('11111111-2222-3333-4444-555555555552', 'bob', 'Bob');

-- The paths are written by the `profile-image` function with the service role,
-- never by the client, so they are set here the same way.
reset role;
reset request.jwt.claim.sub;
update public.pilot_profiles
   set avatar_path = user_id || '/avatar-one.jpg',
       banner_path = user_id || '/banner-one.jpg'
 where handle in ('alice', 'bob');

\echo '--- 1. a clean pilot may upload, and is told nothing'
select count(*) = 0 as no_restriction
  from public.pilot_upload_restriction('11111111-2222-3333-4444-555555555551');
select public.pilot_upload_notice('11111111-2222-3333-4444-555555555551') = ''
  as notice_is_empty_not_null;

\echo '--- 2. the feed shows both pictures, per pilot'
-- Two rows per pilot, one per bucket. A moderator wants to see what has been
-- uploaded, not to pick a bucket before being shown half the answer.
select kind, storage_bucket
  from public.admin_pilot_uploads(200, 0, false)
 where handle = 'alice'
 order by kind;

\echo '--- 3. a takedown records WHICH picture it removed'
-- The one field that says what this record is about. `update ... returning`
-- would store a null here on every single row.
select removed_bucket, removed_path is not null as path_recorded,
       warning_id is null as no_warning_asked_for
  from public.admin_pilot_takedown(
    '11111111-2222-3333-4444-555555555551', 'avatar', 'sexual',
    'note for colleagues', 'moderator-one');

select storage_path = '11111111-2222-3333-4444-555555555551/avatar-one.jpg' as path_kept,
       handle = 'alice' as handle_copied,
       category = 'sexual' as category_kept
  from public.pilot_content_actions
 where user_id = '11111111-2222-3333-4444-555555555551';

select avatar_path is null as column_cleared,
       banner_path is not null as banner_untouched
  from public.pilot_profiles where handle = 'alice';

\echo '--- 4. taking the same picture down twice is refused, not recorded twice'
select public.admin_pilot_takedown(
  '11111111-2222-3333-4444-555555555551', 'avatar', 'other', null, 'moderator-one');

select count(*) = 1 as still_one_record
  from public.pilot_content_actions
 where user_id = '11111111-2222-3333-4444-555555555551';

\echo '--- 5. a takedown can warn and restrict in the same act'
select warning_id is not null as warning_issued
  from public.admin_pilot_takedown(
    '11111111-2222-3333-4444-555555555551', 'banner', 'sexual',
    null, 'moderator-one', 'first', 'Please choose a different picture.', true, 30);

select level, upload_block, upload_block_until is not null as has_expiry,
       category = 'sexual' as category_carried
  from public.pilot_warnings
 where user_id = '11111111-2222-3333-4444-555555555551';

\echo '--- 6. the restriction now holds, and says so in words'
select count(*) = 1 as restricted
  from public.pilot_upload_restriction('11111111-2222-3333-4444-555555555551');

-- The date has to survive to_char without the nine-character blank padding
-- that a bare `Month` produces ("8 September  2026").
select public.pilot_upload_notice('11111111-2222-3333-4444-555555555551') like '%paused%'
       as says_paused,
       public.pilot_upload_notice('11111111-2222-3333-4444-555555555551') not like '%  %'
       as no_double_space;

\echo '--- 7. a warning with no words still says something'
select public.admin_pilot_takedown(
  '11111111-2222-3333-4444-555555555552', 'avatar', 'spam',
  null, 'moderator-one', 'notice', null, false, null);
select char_length(reason) > 20 as reason_composed
  from public.pilot_warnings where user_id = '11111111-2222-3333-4444-555555555552';

\echo '--- 8. the LONGEST block wins, not the newest'
-- The rule that matters. A pilot under an indefinite block who is then given a
-- 7-day one must not be free in seven days, and the newest-first ordering that
-- looks obviously right would do exactly that.
insert into public.pilot_warnings (user_id, level, reason, upload_block, upload_block_until)
  values ('11111111-2222-3333-4444-555555555551', 'final', 'indefinite', true, null);
insert into public.pilot_warnings (user_id, level, reason, upload_block, upload_block_until)
  values ('11111111-2222-3333-4444-555555555551', 'notice', 'short', true, now() + interval '7 days');

select reason = 'indefinite' as indefinite_outranks_dated
  from public.pilot_upload_restriction('11111111-2222-3333-4444-555555555551');

\echo '--- 9. an expired block lapses on its own'
delete from public.pilot_warnings where user_id = '11111111-2222-3333-4444-555555555551';
insert into public.pilot_warnings (user_id, level, reason, upload_block, upload_block_until)
  values ('11111111-2222-3333-4444-555555555551', 'notice', 'lapsed', true, now() - interval '1 day');
select count(*) = 0 as expired_block_is_not_a_block
  from public.pilot_upload_restriction('11111111-2222-3333-4444-555555555551');

\echo '--- 10. rescinding lifts the block; lifting leaves the warning'
delete from public.pilot_warnings where user_id = '11111111-2222-3333-4444-555555555551';
insert into public.pilot_warnings (id, user_id, level, reason, upload_block)
  values ('aaaaaaaa-0000-0000-0000-00000000000a',
          '11111111-2222-3333-4444-555555555551', 'first', 'standing', true);

update public.pilot_warnings set rescinded_at = now()
 where id = 'aaaaaaaa-0000-0000-0000-00000000000a';
select count(*) = 0 as rescinding_lifts_the_block
  from public.pilot_upload_restriction('11111111-2222-3333-4444-555555555551');

update public.pilot_warnings set rescinded_at = null
 where id = 'aaaaaaaa-0000-0000-0000-00000000000a';
select public.admin_pilot_lift_restriction('aaaaaaaa-0000-0000-0000-00000000000a', 'moderator-one')
  as lifted;
select count(*) = 0 as uploads_allowed_again
  from public.pilot_upload_restriction('11111111-2222-3333-4444-555555555551');
-- The point of having two verbs: the warning is still on the record.
select rescinded_at is null as warning_still_stands,
       upload_block_lifted_by = 'moderator-one' as lift_attributed
  from public.pilot_warnings where id = 'aaaaaaaa-0000-0000-0000-00000000000a';

\echo '--- 11. a pilot reads their own warnings and nobody else''s'
set request.jwt.claim.sub = '11111111-2222-3333-4444-555555555551';
set role authenticated;
select count(*) = 1 as sees_own
  from public.pilot_warnings;
select count(*) = 0 as cannot_see_bobs
  from public.pilot_warnings where user_id = '11111111-2222-3333-4444-555555555552';

\echo '--- 12. a pilot cannot write a warning, or lift their own restriction'
-- Refused at the GRANT, before RLS is even consulted: `authenticated` holds
-- select and nothing else on this table. Two locks rather than one, and the
-- outer one is the simpler thing to get right. This is the whole access model,
-- asserted rather than assumed.
insert into public.pilot_warnings (user_id, level, reason)
  values ('11111111-2222-3333-4444-555555555552', 'notice', 'made up');
update public.pilot_warnings set upload_block = false, rescinded_at = now()
 where user_id = '11111111-2222-3333-4444-555555555551';
delete from public.pilot_warnings where user_id = '11111111-2222-3333-4444-555555555551';

\echo '--- 13. and cannot reach the console functions at all'
select public.admin_pilot_uploads(10, 0, false);
select public.admin_pilot_takedown(
  '11111111-2222-3333-4444-555555555552', 'avatar', 'other', null, 'alice');
select public.admin_pilot_lift_restriction('aaaaaaaa-0000-0000-0000-00000000000a', 'alice');
select public.admin_pilot_restrictions();
select public.pilot_upload_restriction('11111111-2222-3333-4444-555555555552');

\echo '--- 14. a pilot sees their own standing, and acknowledges receipt'
select uploads_restricted, active_count, unacknowledged_count,
       jsonb_array_length(warnings) as warning_count
  from public.pilot_my_standing();

select public.pilot_acknowledge_warning('aaaaaaaa-0000-0000-0000-00000000000a') as acknowledged;
select public.pilot_acknowledge_warning('aaaaaaaa-0000-0000-0000-00000000000a') as twice_is_fine;
select unacknowledged_count = 0 as now_acknowledged from public.pilot_my_standing();

\echo '--- 15. acknowledging somebody else''s warning does nothing'
set request.jwt.claim.sub = '11111111-2222-3333-4444-555555555552';
select public.pilot_acknowledge_warning('aaaaaaaa-0000-0000-0000-00000000000a')
  as not_bobs_to_acknowledge;

\echo '--- 16. signed out, standing is silence rather than an error'
-- The `security definer` shape that failed open in 20260818000100 was found
-- exactly here: a signed-out reader must get no rows, not NULL and not a raise.
reset request.jwt.claim.sub;
set role anon;
select count(*) = 0 as no_rows_signed_out from public.pilot_my_standing();

\echo '--- 17. moderation can clear a banner a lapsed-Pro pilot could not set'
-- The write guard refuses a banner from a free account. A takedown is not a
-- client write, so it must sail past that — otherwise the pictures hardest to
-- remove would be the ones on accounts that stopped paying.
reset role;
reset request.jwt.claim.sub;
update public.pilot_profiles set banner_path = 'x/banner-two.jpg' where handle = 'bob';
select removed_path = 'x/banner-two.jpg' as lapsed_pro_banner_removable
  from public.admin_pilot_takedown(
    '11111111-2222-3333-4444-555555555552', 'banner', 'other', null, 'moderator-one');

\echo '--- 18. a pilot with nothing uploaded is not in the feed at all'
-- Every picture on both of these accounts has now been taken down, so the feed
-- is empty even though both pilots have a history. The feed lists PICTURES; a
-- pilot with none is not a row in it, which is why the record and the
-- restrictions list are separate views rather than filters on this one.
select count(*) = 0 as no_pictures_no_rows
  from public.admin_pilot_uploads(200, 0, false);

\echo '--- 19. the flagged filter is the queue, not the whole feed'
-- Alice uploads again. She has two prior takedowns, so she belongs in the
-- flagged queue the moment she has a picture to be flagged about.
update public.pilot_profiles
   set avatar_path = 'alice/avatar-two.jpg' where handle = 'alice';

select handle, prior_takedowns > 0 as has_history
  from public.admin_pilot_uploads(200, 0, true);

\echo '--- 20. the record survives the account it was about'
delete from auth.users where id = '11111111-2222-3333-4444-555555555552';
select count(*) > 0 as actions_kept,
       bool_and(user_id is null) as user_id_nulled,
       bool_and(handle is not null) as handle_still_says_who
  from public.pilot_content_actions where handle = 'bob';

do $$ begin raise notice 'pilot content moderation: assertions above'; end $$;
