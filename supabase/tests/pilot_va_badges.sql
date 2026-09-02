-- What the VA badge column is allowed to hold, and what it is allowed to mean.
--
-- Neither is visible in the schema. `va_ad_ids text[]` looks like a list of
-- whatever you put in it, and the two things that make it safe are both
-- elsewhere: a trigger that normalises what lands, and the fact that NOTHING
-- here decides whether a badge is drawn. The entitlement is resolved in the
-- app, against the partner backend's rosters, every time the badge is drawn —
-- see the migration's own note.
--
-- So what is worth asserting here is exactly the part Postgres does own:
--
--   * the column cannot be used to smuggle something into a URL path, because
--     the ids are pasted into one when the badge is resolved;
--   * it cannot be used to make a profile row unboundedly large;
--   * it keeps the pilot's ORDER, which is the whole meaning of the array;
--   * and the card function actually serves it, to everybody who can see the
--     card at all — because a badge that a viewer never receives is a feature
--     that silently does not exist.
--
-- Run with `supabase/tests/run.sh`.

\set ON_ERROR_STOP off
\pset pager off

insert into auth.users (id, email) values
  ('77777777-7777-7777-7777-777777777777', 'vera@example.com'),
  ('88888888-8888-8888-8888-888888888888', 'wes@example.com');

set request.jwt.claim.sub = '77777777-7777-7777-7777-777777777777';
set role authenticated;

insert into public.pilot_profiles (user_id, handle, display_name, if_username)
  values ('77777777-7777-7777-7777-777777777777', 'vera', 'Vera', 'vera_if');

\echo '--- 1. a plain list is kept exactly as it was given'
-- Order first, because order is what the array MEANS: it is which VA leads the
-- profile header, so anything that sorts or de-orders it has quietly changed
-- the pilot's answer rather than tidied it.
update public.pilot_profiles
   set va_ad_ids = array['ccc1111111111111', 'aaa2222222222222', 'bbb3333333333333']
 where user_id = '77777777-7777-7777-7777-777777777777';
select va_ad_ids[1] = 'ccc1111111111111' as first_stayed_first,
       va_ad_ids[2] = 'aaa2222222222222' as second_stayed_second,
       va_ad_ids[3] = 'bbb3333333333333' as third_stayed_third
  from public.pilot_profiles where handle = 'vera';

\echo '--- 2. anything that is not an id shape is dropped, not stored'
-- The ids are pasted into `/api/va-ads/for-pilot`-adjacent paths by the client
-- that resolves them. A slash or a space reaching that point is the bug this
-- line exists to make impossible, and it is dropped here rather than escaped
-- three layers away.
update public.pilot_profiles
   set va_ad_ids = array['good111', '../../etc/passwd', 'has space', '', '  ', 'good222']
 where user_id = '77777777-7777-7777-7777-777777777777';
select va_ad_ids as survivors,
       array_length(va_ad_ids, 1) = 2 as only_the_two_good_ones
  from public.pilot_profiles where handle = 'vera';

\echo '--- 3. duplicates collapse, keeping the first mention'
update public.pilot_profiles
   set va_ad_ids = array['dup1', 'other', 'dup1', 'dup1']
 where user_id = '77777777-7777-7777-7777-777777777777';
select va_ad_ids as deduped,
       va_ad_ids[1] = 'dup1' as first_mention_won,
       array_length(va_ad_ids, 1) = 2 as collapsed
  from public.pilot_profiles where handle = 'vera';

\echo '--- 4. a pilot cannot wear more than the header draws'
-- Capped rather than refused. A refusal would be a save that fails for a
-- reason the profile editor cannot explain, and the editor already stops at
-- three — this is the floor under it, not the message to the pilot.
update public.pilot_profiles
   set va_ad_ids = array['v1', 'v2', 'v3', 'v4', 'v5', 'v6', 'v7', 'v8', 'v9']
 where user_id = '77777777-7777-7777-7777-777777777777';
select array_length(va_ad_ids, 1) = 3 as capped_at_three,
       va_ad_ids = array['v1', 'v2', 'v3'] as kept_the_first_three
  from public.pilot_profiles where handle = 'vera';

\echo '--- 5. an unset column is an empty list, never null'
-- Because the app reads it as a list on every card, and a null arriving where
-- an array was promised is a decode failure that costs the whole profile
-- rather than the badge.
-- Wes files his own row, so the switch of identity comes BEFORE the insert:
-- row-level security is what decides whose row this is, and a row filed while
-- still wearing Vera's token is refused rather than misattributed.
reset role;
set request.jwt.claim.sub = '88888888-8888-8888-8888-888888888888';
set role authenticated;
insert into public.pilot_profiles (user_id, handle, display_name)
  values ('88888888-8888-8888-8888-888888888888', 'wes', 'Wes');
select va_ad_ids is not null as never_null,
       array_length(va_ad_ids, 1) is null as empty
  from public.pilot_profiles where handle = 'wes';

\echo '--- 6. the card serves the ids to a signed-in stranger'
-- Wes is not Vera and follows nobody. The badge is not a Pro column and not a
-- friends-only one: which VAs somebody flies for is not ours to ration, and a
-- badge only its owner can see is not a badge.
select va_ad_ids as stranger_sees
  from public.pilot_profile_card('vera');

\echo '--- 7. and to a signed-out reader'
reset role;
reset request.jwt.claim.sub;
set role anon;
select va_ad_ids as anon_sees,
       array_length(va_ad_ids, 1) = 3 as all_three
  from public.pilot_profile_card('vera');

\echo '--- 8. the by-username card carries it too'
-- The function every tapped aeroplane goes through. It delegates to the card
-- above, so this is really a check that its rebuilt SIGNATURE gained the
-- column — a delegation that returns one fewer column than it declares is an
-- error at call time, not at create time.
select va_ad_ids as by_username_sees
  from public.pilot_profile_by_if_username('vera_if');

reset role;
