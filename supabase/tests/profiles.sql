-- What the profile schema is supposed to do, asserted by reading the output.
-- Run with supabase/tests/run.sh.

\set ON_ERROR_STOP off
\pset pager off

-- Four accounts: a Pro one, two free ones, and a stranger.
insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'pro@example.com'),
  ('22222222-2222-2222-2222-222222222222', 'free@example.com'),
  ('33333333-3333-3333-3333-333333333333', 'mate@example.com'),
  ('44444444-4444-4444-4444-444444444444', 'nosy@example.com');
insert into public.profiles (id) select id from auth.users;

-- Pro, by way of a live App Store subscription.
insert into public.app_store_subscriptions
  (original_transaction_id, user_id, product_id, kind, status, expires_at, environment)
values ('otx-1', '11111111-1111-1111-1111-111111111111',
        'com.tracker.Inflight.pro.annual', 'subscription', 'active',
        now() + interval '300 days', 'Production');

\echo '--- 1. entitlement helper'
select 'pro'  as who, public.is_pro_account('11111111-1111-1111-1111-111111111111') as is_pro
union all select 'free', public.is_pro_account('22222222-2222-2222-2222-222222222222')
union all select 'nobody', public.is_pro_account(null);

\echo '--- 2. claiming handles'
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
set role authenticated;
insert into public.pilot_profiles (user_id, handle, display_name, bio, if_username,
                                   favourite_aircraft, favourite_livery, home_airport)
values ('11111111-1111-1111-1111-111111111111', 'Speedbird', 'Speedbird',
        'Long haul, mostly.', 'speedbird_49', 'Boeing 777-300ER', 'British Airways', 'egll');
select handle, home_airport from public.pilot_profiles where user_id = '11111111-1111-1111-1111-111111111111';

\echo '--- 2a. a reserved handle is refused'
insert into public.pilot_profiles (user_id, handle) values
  ('11111111-1111-1111-1111-111111111111', 'admin');

\echo '--- 2b. a handle shaped wrong is refused'
reset role; set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222'; set role authenticated;
insert into public.pilot_profiles (user_id, handle) values
  ('22222222-2222-2222-2222-222222222222', '_nope_');

\echo '--- 2c. an unsafe handle is refused (leetspeak included)'
insert into public.pilot_profiles (user_id, handle) values
  ('22222222-2222-2222-2222-222222222222', 'p0rnjet');

\echo '--- 2d. an unsafe bio is refused'
insert into public.pilot_profiles (user_id, handle, bio) values
  ('22222222-2222-2222-2222-222222222222', 'freebird', 'Follow me on 0nlyfans');

\echo '--- 2e. a normal free profile is fine'
insert into public.pilot_profiles (user_id, handle, display_name, if_username, favourite_aircraft)
values ('22222222-2222-2222-2222-222222222222', 'freebird', 'Free Bird', 'freebird', 'Airbus A320');
select handle from public.pilot_profiles where user_id = '22222222-2222-2222-2222-222222222222';

\echo '--- 3. PRO GATE: a free account may not set a banner or an accent'
update public.pilot_profiles set banner_path = 'sneaky.jpg'
 where user_id = '22222222-2222-2222-2222-222222222222';
update public.pilot_profiles set accent = '#ff0000'
 where user_id = '22222222-2222-2222-2222-222222222222';

\echo '--- 3a. ...and may not write somebody else''s row at all'
update public.pilot_profiles set display_name = 'hacked'
 where user_id = '11111111-1111-1111-1111-111111111111';
select display_name from public.pilot_profiles where user_id = '11111111-1111-1111-1111-111111111111';

\echo '--- 3b. ...nor its own moderation state'
update public.pilot_profiles set moderation_state = 'ok', is_public = true
 where user_id = '22222222-2222-2222-2222-222222222222';

\echo '--- 3c. a Pro account may'
reset role; set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111'; set role authenticated;
update public.pilot_profiles set banner_path = '1111/banner.jpg', accent = '#1e3a8a'
 where user_id = '11111111-1111-1111-1111-111111111111';
select banner_path, accent from public.pilot_profiles
 where user_id = '11111111-1111-1111-1111-111111111111';

\echo '--- 4. following and friends'
reset role; set request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333'; set role authenticated;
insert into public.pilot_profiles (user_id, handle, display_name, if_username)
values ('33333333-3333-3333-3333-333333333333', 'tailwind', 'Tailwind', 'tailwind');
select public.pilot_follow('speedbird') as now_friends;
reset role; set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111'; set role authenticated;
select public.pilot_follow('tailwind') as now_friends;

\echo '--- 4a. the card, as a stranger sees it'
reset role; set request.jwt.claim.sub = ''; set role anon;
select handle, display_name, banner_path, accent, is_pro,
       follower_count, following_count, friend_count, viewer_follows, is_self
  from public.pilot_profile_card('speedbird');

\echo '--- 4b. and the friends list'
select handle, display_name, is_pro from public.pilot_profile_friends('speedbird');

\echo '--- 4c. found from the name on the map'
select handle, if_username, if_username_verified from public.pilot_profile_by_if_username('SPEEDBIRD_49');

\echo '--- 4d. a free account''s card never carries a banner'
reset role; set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111'; set role authenticated;
update public.pilot_profiles set banner_path = '3333/b.jpg'
  where user_id = '11111111-1111-1111-1111-111111111111';
reset role;
-- revoke the Pro subscription and re-read the same row
update public.app_store_subscriptions set revoked_at = now() where original_transaction_id = 'otx-1';
set request.jwt.claim.sub = ''; set role anon;
select handle, is_pro, banner_path, accent, banner_preset
  from public.pilot_profile_card('speedbird');
reset role;
update public.app_store_subscriptions set revoked_at = null where original_transaction_id = 'otx-1';

\echo '--- 5. blocking'
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111'; set role authenticated;
select public.pilot_block('tailwind', true);
select count(*) as follows_left from public.pilot_follows
 where follower_id in ('11111111-1111-1111-1111-111111111111','33333333-3333-3333-3333-333333333333')
   and following_id in ('11111111-1111-1111-1111-111111111111','33333333-3333-3333-3333-333333333333');
reset role; set request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333'; set role authenticated;
\echo '    a blocked pilot sees nothing:'
select count(*) as card_rows from public.pilot_profile_card('speedbird');
\echo '    ...and cannot follow again:'
select public.pilot_follow('speedbird');
reset role; set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111'; set role authenticated;
select public.pilot_block('tailwind', false);

\echo '--- 6. reports hide a profile after three'
reset role;
do $$
declare v uuid;
begin
  for v in select unnest(array['22222222-2222-2222-2222-222222222222'::uuid,
                              '33333333-3333-3333-3333-333333333333'::uuid,
                              '44444444-4444-4444-4444-444444444444'::uuid]) loop
    perform set_config('request.jwt.claim.sub', v::text, true);
    perform public.pilot_report('speedbird', 'sexual', 'test');
  end loop;
end $$;
select public.profile_is_autohidden('11111111-1111-1111-1111-111111111111') as autohidden;
set request.jwt.claim.sub = ''; set role anon;
select count(*) as visible_to_strangers from public.pilot_profile_card('speedbird');
select count(*) as friends_of_a_hidden_profile from public.pilot_profile_friends('speedbird');
reset role;
update public.profile_reports set resolved_at = now();
set request.jwt.claim.sub = ''; set role anon;
select count(*) as visible_once_resolved from public.pilot_profile_card('speedbird');
reset role;

\echo '--- 7. the logbook, free and Pro'
insert into public.pilot_logbook
  (user_id, flight_id, aircraft, origin_icao, destination_icao, minutes, distance_nm,
   max_altitude_feet, landed_at)
select '22222222-2222-2222-2222-222222222222',
       'f' || g, 'Airbus A320', 'EGLL', 'LFPG', 75, 190, 36000, now() - (g || ' hours')::interval
  from generate_series(1, 35) g;
set request.jwt.claim.sub = ''; set role anon;
select count(*) as entries_free, bool_or(truncated) as says_truncated
  from public.pilot_logbook_entries('freebird', 200);
select flights, minutes, airports, aircraft_types, regions, top_aircraft, top_route
  from public.pilot_logbook_summary('freebird');
reset role;
insert into public.app_store_subscriptions
  (original_transaction_id, user_id, product_id, kind, status, expires_at, environment)
values ('otx-2', '22222222-2222-2222-2222-222222222222',
        'com.tracker.Inflight.pro.monthly', 'subscription', 'active',
        now() + interval '20 days', 'Production');
set request.jwt.claim.sub = ''; set role anon;
select count(*) as entries_pro, bool_or(truncated) as says_truncated
  from public.pilot_logbook_entries('freebird', 200);

\echo '--- 8. badges'
select code, target, progress, earned from public.pilot_badges('freebird')
 where family in ('flights','airports') order by family, target;

\echo '--- 9. a private logbook says nothing'
reset role; set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222'; set role authenticated;
update public.pilot_profiles set logbook_visibility = 'private'
 where user_id = '22222222-2222-2222-2222-222222222222';
reset role; set request.jwt.claim.sub = ''; set role anon;
select count(*) as private_entries from public.pilot_logbook_entries('freebird', 200);
select count(*) as private_badges from public.pilot_badges('freebird');
select count(*) as card_still_visible from public.pilot_profile_card('freebird');

\echo '--- 10. directory search'
select handle, display_name from public.pilot_directory_search('sp');
select count(*) as too_short from public.pilot_directory_search('s');
reset role;

\echo '--- 11. the handle cooldown'
set request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333'; set role authenticated;
update public.pilot_profiles set handle = 'tailwind2' where user_id = '33333333-3333-3333-3333-333333333333';
reset role;
