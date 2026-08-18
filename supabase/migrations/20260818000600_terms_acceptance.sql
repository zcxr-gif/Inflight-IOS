-- Who agreed to what, and when.
--
-- The tracker works signed out, so the device is the primary record — see
-- `TermsStore`. This is the second copy, and it exists for two reasons the
-- device cannot serve: agreement has to survive a reinstall, and there has to
-- be a record on the server of which version somebody accepted. An agreement
-- that lives only in a preferences file on a phone is not a record of anything.
--
-- Kept on `profiles` rather than in a table of its own. There is exactly one
-- current answer per account, it is small, and it is read whenever the account
-- is — a separate table would be a join for two columns.

alter table public.profiles
  add column if not exists terms_version integer,
  add column if not exists terms_accepted_at timestamptz;

comment on column public.profiles.terms_version is
  'Which version of the Terms of Service this account has agreed to. Null for accounts made before the gate shipped; see the note in record_terms_acceptance.';

-- MARK: - Recording one
--
-- A function rather than letting the client write the columns directly, for the
-- same reason `moderation_state` is not the client's to set: an account that
-- can write its own acceptance can write one it never made. This runs as the
-- owner, takes the id from the token, and refuses to move backwards.

create or replace function public.record_terms_acceptance(
  p_version integer,
  p_accepted_at timestamptz default now()
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'Sign in first.' using errcode = 'insufficient_privilege';
  end if;

  if p_version is null or p_version < 1 then
    raise exception 'That is not a terms version.' using errcode = 'invalid_parameter_value';
  end if;

  -- A timestamp from a client is a claim, and a client whose clock is wrong --
  -- or which is lying -- must not be able to record an agreement in the future
  -- or one from before the account existed. Anything outside a sane window is
  -- replaced with the server's own clock rather than rejected: the agreement
  -- did happen, and refusing it over a wrong clock would leave somebody unable
  -- to use the app.
  if p_accepted_at is null
     or p_accepted_at > now() + interval '1 day'
     or p_accepted_at < now() - interval '10 years' then
    p_accepted_at := now();
  end if;

  update public.profiles p
     set terms_version = p_version,
         terms_accepted_at = p_accepted_at
   where p.id = v_uid
     -- Only ever forwards. The app calls this on every sign-in, and a device
     -- carrying a stale acceptance must not overwrite a newer one made
     -- somewhere else.
     and (p.terms_version is null or p.terms_version < p_version);
end $function$;

grant execute on function public.record_terms_acceptance(integer, timestamptz) to authenticated;

-- MARK: - Reading your own back
--
-- So a client that has lost its local copy -- a reinstall -- can find out it
-- has already agreed, rather than asking again.

create or replace function public.my_terms_acceptance()
returns table (
  terms_version integer,
  terms_accepted_at timestamptz
)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select p.terms_version, p.terms_accepted_at
    from public.profiles p
   where p.id = auth.uid();
$function$;

grant execute on function public.my_terms_acceptance() to authenticated;
