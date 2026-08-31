-- The rules on the settings blob, none of which are visible in its shape.
--
-- The table is one column of opaque JSON, so there is nothing here to get
-- wrong about *contents*. What there is to get wrong is everything around it:
-- whose row it is, whether it can be made to change hands, whether the clock
-- the client syncs against is the client's or the server's, and whether an
-- unbounded client-writable column is in fact bounded. Each of those is one
-- line in the migration and a data breach or an outage if the line is wrong.
--
-- Run with `supabase/tests/run.sh`.

\set ON_ERROR_STOP off
\pset pager off

-- Two pilots, so "mine" and "not mine" are both real.
insert into auth.users (id, email) values
  ('55555555-5555-5555-5555-555555555555', 'ada@example.com'),
  ('66666666-6666-6666-6666-666666666666', 'bo@example.com');

\echo '--- 1. a row is filed against the caller, without being told who that is'
set request.jwt.claim.sub = '55555555-5555-5555-5555-555555555555';
set role authenticated;
insert into public.pilot_settings (settings)
  values ('{"watchlist": ["speedbird_49"]}'::jsonb);
select user_id = '55555555-5555-5555-5555-555555555555' as filed_against_caller,
       revision,
       settings -> 'watchlist' as watchlist
  from public.pilot_settings;

\echo '--- 2. a row sent under somebody else''s name is corrected, not honoured'
-- Bo, who has no row yet, files one claiming Ada's account. The guard rewrites
-- `user_id` to the caller before row-level security sees it, so what lands is
-- Bo's own row and Ada's is untouched. Corrected rather than refused is worth
-- being precise about: the policy alone would reject this, and the trigger
-- means a client never has to know its own id to write.
reset role;
set request.jwt.claim.sub = '66666666-6666-6666-6666-666666666666';
set role authenticated;
insert into public.pilot_settings (user_id, settings)
  values ('55555555-5555-5555-5555-555555555555', '{"stolen": true}'::jsonb);
select user_id = '66666666-6666-6666-6666-666666666666' as landed_as_the_caller
  from public.pilot_settings;

reset role;
set request.jwt.claim.sub = '55555555-5555-5555-5555-555555555555';
set role authenticated;
select settings ? 'stolen' as ada_was_touched from public.pilot_settings;

\echo '--- 3. a row does not change hands on update'
update public.pilot_settings
   set user_id = '66666666-6666-6666-6666-666666666666',
       settings = '{"watchlist": ["speedbird_49", "heavy_42"]}'::jsonb;
select user_id = '55555555-5555-5555-5555-555555555555' as still_mine,
       jsonb_array_length(settings -> 'watchlist') as names
  from public.pilot_settings;

\echo '--- 4. settings must be an object, not an array or a scalar'
update public.pilot_settings set settings = '[1,2,3]'::jsonb;
update public.pilot_settings set settings = '"nope"'::jsonb;

\echo '--- 5. and must fit inside the ceiling'
update public.pilot_settings
   set settings = jsonb_build_object('junk', repeat('x', 70000));

\echo '--- 6. a blob just under it is fine'
update public.pilot_settings
   set settings = jsonb_build_object('junk', repeat('x', 60000));
select octet_length(settings::text) between 60000 and 65536 as within_ceiling
  from public.pilot_settings;

\echo '--- 7. bo cannot read or write ada''s row'
reset role;
set request.jwt.claim.sub = '66666666-6666-6666-6666-666666666666';
set role authenticated;
-- Bo has a row of their own by now, so the question is not how many rows are
-- visible but whether Ada's is one of them.
select count(*) as adas_rows_bo_can_see from public.pilot_settings
 where user_id = '55555555-5555-5555-5555-555555555555';
update public.pilot_settings
   set settings = '{"vandalised": true}'::jsonb
 where user_id = '55555555-5555-5555-5555-555555555555';
reset role;
select count(*) as rows_bo_changed from public.pilot_settings
 where settings ? 'vandalised';

\echo '--- 8. and a signed-out caller sees nothing at all'
reset role;
set request.jwt.claim.sub = '';
set role anon;
select count(*) as rows_anon_can_see from public.pilot_settings;

\echo '--- 8a. the upsert the app actually sends'
reset role;
set request.jwt.claim.sub = '55555555-5555-5555-5555-555555555555';
set role authenticated;
-- PostgREST turns `Prefer: resolution=merge-duplicates` into exactly this, and
-- it is the only write the client makes: one call that does not need to know
-- whether the account has been synced before. Worth its own case because it
-- takes a different path through the policies -- the INSERT check on the way
-- in and the UPDATE check on the conflict -- and a schema that allows a plain
-- insert can still refuse this one.
insert into public.pilot_settings (settings, revision)
  values ('{"watchlist": ["heavy_42"], "mapPalette": "black"}'::jsonb, 1)
  on conflict (user_id) do update
    set settings = excluded.settings, revision = excluded.revision;
select settings ->> 'mapPalette' as palette,
       jsonb_array_length(settings -> 'watchlist') as names
  from public.pilot_settings
 where user_id = '55555555-5555-5555-5555-555555555555';

\echo '--- 9. the clock is the server''s, and created_at is frozen'
reset role;
set request.jwt.claim.sub = '55555555-5555-5555-5555-555555555555';
set role authenticated;

\set ON_ERROR_STOP on
do $$
declare
  ada uuid := '55555555-5555-5555-5555-555555555555';
  before_created timestamptz;
  before_updated timestamptz;
  r record;
begin
  select created_at, updated_at into before_created, before_updated
    from public.pilot_settings where user_id = ada;

  -- A client sending its own timestamps is ignored on both counts. This is
  -- what the whole sync leans on: the device decides whether the account knows
  -- something newer by comparing against `updated_at`, and a clock the client
  -- could set is a clock it could set backwards.
  update public.pilot_settings
     set settings = '{"watchlist": []}'::jsonb,
         created_at = now() - interval '10 years',
         updated_at = now() - interval '10 years'
   where user_id = ada;

  select * into r from public.pilot_settings where user_id = ada;

  assert r.created_at = before_created,
    'created_at is frozen at the insert, whatever the client sends';
  assert r.updated_at >= before_updated,
    'updated_at is the server clock, never the client''s';
  assert r.updated_at > now() - interval '1 minute',
    'and it is now, not the decade-old value that was sent';
end;
$$;

\echo '--- 10. deleting the account takes the settings with it'
reset role;
delete from auth.users where id = '55555555-5555-5555-5555-555555555555';
select count(*) as rows_left from public.pilot_settings
 where user_id = '55555555-5555-5555-5555-555555555555';

reset role;
set request.jwt.claim.sub = '';
delete from auth.users where id = '66666666-6666-6666-6666-666666666666';
select count(*) as rows_left_at_all from public.pilot_settings;
