-- Closing what Postgres opens by default.
--
-- `create function` grants EXECUTE to PUBLIC unless told otherwise. Granting it
-- to `authenticated` afterwards does not take that away — it adds a second,
-- redundant grant on top of one already given to everybody, `anon` included.
-- Every migration in this schema that mattered got this right by revoking
-- explicitly (`is_pro_account`, `profile_is_autohidden`), and the live-status
-- and terms migrations did not. Supabase's own security advisor is what caught
-- it.
--
-- HOW BAD WAS IT. Not very, and that is not the point. Every one of these is
-- written to be safe with no caller: `pilot_live_clear` deletes where
-- `user_id = auth.uid()` and anon's is null, `record_terms_acceptance` raises
-- rather than writing, the read functions return no rows. So an anonymous
-- caller got nothing from any of them. But "safe because every function
-- happens to check" is a property that holds until somebody writes one that
-- does not, and the grant is the thing that should have been wrong for that to
-- matter.
--
-- `pilot_live_readable` is the one worth naming. It is an internal helper —
-- the shared definition of "may this person see this pilot's live status" —
-- and it has no business being callable by anybody at all, exactly like the
-- two siblings this file's predecessor remembered to revoke.

-- MARK: - Internal helpers: nobody

revoke all on function public.pilot_live_readable(public.pilot_profiles, uuid) from public;
revoke all on function public.pilot_live_readable(public.pilot_profiles, uuid) from anon;
revoke all on function public.pilot_live_readable(public.pilot_profiles, uuid) from authenticated;

-- MARK: - Signed in only
--
-- Each of these is meaningless without an account: they act on, or report to,
-- `auth.uid()`. Revoked from PUBLIC first — which is what the original grants
-- missed — and then granted back to the one role that should have them.

revoke all on function public.pilot_live_clear() from public;
grant execute on function public.pilot_live_clear() to authenticated;

revoke all on function public.pilot_live_following(integer) from public;
grant execute on function public.pilot_live_following(integer) to authenticated;

revoke all on function public.pilot_landing_board(integer, integer) from public;
grant execute on function public.pilot_landing_board(integer, integer) to authenticated;

revoke all on function public.record_terms_acceptance(integer, timestamptz) from public;
grant execute on function public.record_terms_acceptance(integer, timestamptz) to authenticated;

revoke all on function public.my_terms_acceptance() from public;
grant execute on function public.my_terms_acceptance() to authenticated;

-- MARK: - Deliberately open
--
-- `pilot_live_status_for` stays readable by `anon`, and that is the design
-- rather than an oversight: the website serves these profiles to people who
-- have never signed in, and a signed-out reader has `auth.uid() = null`, which
-- `pilot_live_readable` resolves to "only profiles whose live_visibility is
-- public". Re-granted explicitly here so the intent is written down next to
-- the revocations rather than inferred from their absence.
revoke all on function public.pilot_live_status_for(text) from public;
grant execute on function public.pilot_live_status_for(text) to anon, authenticated;

-- MARK: - A fixed search_path on the constant functions
--
-- These take no arguments and read no tables — `select 100` and
-- `select interval '4 minutes'` — so there is no injection to perform through
-- an unqualified name. Set anyway: the rule is that a function in this schema
-- pins its search_path, and a rule with exceptions somebody has to remember is
-- not a rule.

create or replace function public.logbook_greaser_fpm()
returns integer language sql immutable
set search_path to 'public'
as $function$ select 100 $function$;

create or replace function public.live_status_ttl()
returns interval language sql immutable
set search_path to 'public'
as $function$ select interval '4 minutes' $function$;

create or replace function public.pilot_logbook_free_entries()
returns integer language sql immutable
set search_path to 'public'
as $function$ select 20 $function$;

create or replace function public.profile_autohide_threshold()
returns integer language sql immutable
set search_path to 'public'
as $function$ select 3 $function$;

-- This one does read a table indirectly through nothing, but it does call
-- `regexp_replace` and `translate` unqualified, which is exactly the shape a
-- search_path attack takes.
create or replace function public.moderation_normalize(p_text text)
returns text
language sql
immutable
set search_path to 'public'
as $function$
  select regexp_replace(
           regexp_replace(
             regexp_replace(
               translate(lower(coalesce(p_text, '')),
                         '4310$!5|@+',
                         'aeiosisita'),
               '[^a-z ]+', '', 'g'),
             '(.)\1+', '\1', 'g'),
           ' +', ' ', 'g');
$function$;
