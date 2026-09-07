-- Deleting an account has to actually delete the account.
--
-- This is the test that did not exist when in-app deletion quietly stopped
-- working. The button was wired, the Edge Function was deployed, and the
-- delete failed at the last step every time for anybody who had founded a
-- virtual airline: `vas.ceo_user_id` referenced `auth.users` with no delete
-- rule, and Postgres refuses to delete a row anything still points at. Nothing
-- in the schema said so, nothing in a diff showed it, and the app reported
-- "try again" — advice that could never work.
--
-- Two things are checked here, and they are different kinds of check.
--
--   1. THE INVARIANT. `account_deletion_blockers()` names every foreign key to
--      `auth.users` that would refuse a delete. It must answer with nothing.
--      This is the one that catches the *next* table, added by anybody, in any
--      repository — the whole failure was a table added elsewhere.
--   2. THE BEHAVIOUR. A pilot with a row in every table this repo owns is
--      deleted, and every one of those rows has to go with them, while a
--      second pilot's rows stay exactly as they were.
--
-- Run with `supabase/tests/run.sh`.

\set ON_ERROR_STOP on
\pset pager off

\echo '--- 1. nothing in the schema refuses a user delete'
-- Empty is the pass. A row here is a table that will break account deletion —
-- and App Store review with it — the day one pilot has a row in it.
select table_name, constraint_name, definition
  from public.account_deletion_blockers();

select count(*) = 0 as no_blockers from public.account_deletion_blockers();

\echo '--- 2. the alarm actually rings'
-- A table shaped like the one that caused the bug: a reference to `auth.users`
-- with no delete rule. If this does not show up, check 1 above is decorative.
create table public.deletion_canary (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users (id)
);

select count(*) = 1 as canary_reported
  from public.account_deletion_blockers()
 where table_name = 'deletion_canary';

drop table public.deletion_canary;

\echo '--- 3. a fully furnished pilot, erased'
insert into auth.users (id, email) values
  ('77777777-7777-7777-7777-777777777777', 'leaving@example.com'),
  ('88888888-8888-8888-8888-888888888888', 'staying@example.com');

insert into public.profiles (id) values
  ('77777777-7777-7777-7777-777777777777'),
  ('88888888-8888-8888-8888-888888888888')
  on conflict (id) do nothing;

insert into public.pilot_profiles (user_id, handle, if_username)
  values ('77777777-7777-7777-7777-777777777777', 'leaving', 'Leaving');
insert into public.pilot_profiles (user_id, handle)
  values ('88888888-8888-8888-8888-888888888888', 'staying');

insert into public.pilot_settings (user_id, settings)
  values ('77777777-7777-7777-7777-777777777777', '{"watchlist": ["speedbird_49"]}'::jsonb);
insert into public.pilot_logbook (user_id) values ('77777777-7777-7777-7777-777777777777');
insert into public.pilot_live_status (user_id) values ('77777777-7777-7777-7777-777777777777');
insert into public.pilot_flight_plans (user_id, origin_icao, destination_icao)
  values ('77777777-7777-7777-7777-777777777777', 'EGLL', 'KJFK');

-- Both directions of both relationships, because a follow and a block each
-- name two accounts and only one of them is leaving.
insert into public.pilot_follows (follower_id, following_id) values
  ('77777777-7777-7777-7777-777777777777', '88888888-8888-8888-8888-888888888888'),
  ('88888888-8888-8888-8888-888888888888', '77777777-7777-7777-7777-777777777777');
insert into public.pilot_blocks (blocker_id, blocked_id) values
  ('77777777-7777-7777-7777-777777777777', '88888888-8888-8888-8888-888888888888'),
  ('88888888-8888-8888-8888-888888888888', '77777777-7777-7777-7777-777777777777');

insert into public.app_store_subscriptions (original_transaction_id, user_id, product_id)
  values ('2000000999', '77777777-7777-7777-7777-777777777777', 'com.tracker.Inflight.pro');

-- A report they filed on somebody else, and one somebody else filed on them.
insert into public.profile_reports (profile_id, reporter_id, reason) values
  ('88888888-8888-8888-8888-888888888888', '77777777-7777-7777-7777-777777777777', 'spam'),
  ('77777777-7777-7777-7777-777777777777', '88888888-8888-8888-8888-888888888888', 'spam');

delete from auth.users where id = '77777777-7777-7777-7777-777777777777';

\echo '--- 4. nothing of theirs is left'
select
  (select count(*) from public.profiles where id = '77777777-7777-7777-7777-777777777777')
+ (select count(*) from public.pilot_profiles where user_id = '77777777-7777-7777-7777-777777777777')
+ (select count(*) from public.pilot_settings where user_id = '77777777-7777-7777-7777-777777777777')
+ (select count(*) from public.pilot_logbook where user_id = '77777777-7777-7777-7777-777777777777')
+ (select count(*) from public.pilot_live_status where user_id = '77777777-7777-7777-7777-777777777777')
+ (select count(*) from public.pilot_flight_plans where user_id = '77777777-7777-7777-7777-777777777777')
+ (select count(*) from public.pilot_follows
    where follower_id = '77777777-7777-7777-7777-777777777777'
       or following_id = '77777777-7777-7777-7777-777777777777')
+ (select count(*) from public.pilot_blocks
    where blocker_id = '77777777-7777-7777-7777-777777777777'
       or blocked_id = '77777777-7777-7777-7777-777777777777')
+ (select count(*) from public.app_store_subscriptions where user_id = '77777777-7777-7777-7777-777777777777')
+ (select count(*) from public.profile_reports where profile_id = '77777777-7777-7777-7777-777777777777')
  as rows_still_naming_them;

\echo '--- 5. and the handle is free for whoever wants it next'
-- Including them: deleting and signing up again has to be able to give a pilot
-- their own handle back, which it cannot if the profile row outlives them.
select not exists (
  select 1 from public.pilot_profiles where handle = 'leaving'
) as handle_released;

\echo '--- 6. the Apple purchase can move to a new account'
-- `app_store_subscriptions` is keyed on Apple's original transaction id, so a
-- row left behind would belong to a deleted account for ever and the same
-- purchase could never be linked again. Somebody who deletes their account and
-- signs up afresh still owns what they bought.
select not exists (
  select 1 from public.app_store_subscriptions where original_transaction_id = '2000000999'
) as purchase_relinkable;

\echo '--- 7. what they did to other people survives, without their name on it'
-- The report they filed stays — it is about the pilot they reported, and
-- moderation would otherwise be undone by the reporter walking away — but
-- `reporter_id` is `on delete set null`, so it no longer names them.
select count(*) as reports_kept,
       count(*) filter (where reporter_id is null) as reports_anonymised
  from public.profile_reports
 where profile_id = '88888888-8888-8888-8888-888888888888';

\echo '--- 8. the pilot who stayed is untouched'
select
  (select count(*) from public.pilot_profiles where user_id = '88888888-8888-8888-8888-888888888888') as profile,
  (select count(*) from public.profile_reports where profile_id = '88888888-8888-8888-8888-888888888888') as reported;
