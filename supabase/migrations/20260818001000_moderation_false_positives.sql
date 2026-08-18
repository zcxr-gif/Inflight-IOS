-- The filter was rejecting the letter "x".
--
-- `moderation_normalize` collapsed runs of the same letter so that "pooorn"
-- would be caught by the term "porn". It did that to the TERM as well as to
-- the text — and `xxx` collapsed to `x`, which was then matched as a
-- SUBSTRING. Every profile containing the letter x anywhere was refused:
--
--     Max · Alex · Texas · Expert Server · MXP · Essex · A350 and MAX
--
-- all rejected, with a message that said only "please choose different
-- wording" and gave no clue which of four fields had failed or why. That is
-- the worst kind of bug: it hit ordinary users, it was silent about its
-- reason, and the thing it was protecting against was not present.
--
-- THE REAL FIX IS NOT DELETING `xxx`. Collapsing runs on both sides is wrong
-- in general — it destroys any term whose identity is a repeated letter, and
-- it mangles the text as well ("Essex" became "esex"). Letter-stretching is
-- better handled where it belongs: in the pattern. A term is compiled to a
-- regex that allows each of its letters to repeat, so
--
--     porn  ->  p+o+r+n+     matches "porn", "pooorn", "ppp0rrrn"
--     xxx   ->  x+x+x+       matches "xxx", "xxxx" -- and NOT the x in "Max"
--
-- which catches strictly more evasion than run-collapsing did, and stops
-- catching aeroplanes.

-- MARK: - Normalising, without destroying the text
--
-- Lowercase, fold the usual character substitutions, drop anything that is not
-- a letter or a space, and squeeze runs of spaces. Runs of LETTERS are now left
-- alone; the pattern below is what tolerates them.
--
-- The substitution table also had two entries the wrong way round: '@' mapped
-- to 't' and '+' to 'a'. '@' looks like an 'a' and '+' looks like a 't'.
create or replace function public.moderation_normalize(p_text text)
returns text
language sql
immutable
set search_path to 'public'
as $function$
  select btrim(regexp_replace(
           regexp_replace(
             translate(lower(coalesce(p_text, '')),
                       '4310$!5|@+',
                       'aeiosisiat'),
             '[^a-z ]+', '', 'g'),
           ' +', ' ', 'g'));
$function$;

-- MARK: - A term, as a pattern
--
-- Every letter may repeat. Terms are normalised first, so they contain nothing
-- but a-z and spaces and there is no regex metacharacter to escape — which is
-- the reason this is safe to build by string concatenation.
create or replace function public.moderation_pattern(p_term text)
returns text
language sql
immutable
set search_path to 'public'
as $function$
  select regexp_replace(public.moderation_normalize(p_term), '(.)', '\1+', 'g');
$function$;

-- MARK: - The check
--
-- Two rails that were not there before:
--
--   * a SUBSTRING term must normalise to at least three characters. A one- or
--     two-letter substring matches half the dictionary, and the only way such
--     a term gets into the table is by accident — which is exactly how `xxx`
--     became `x`. A short term is ignored rather than enforced, because
--     silently matching everything is worse than silently matching nothing.
--   * empty text is never rejected. `position('' in '')` was answering in ways
--     that only ever produced false positives.
create or replace function public.moderation_rejects(p_text text)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $function$
  select case
    when public.moderation_normalize(p_text) = '' then false
    else exists (
      select 1
        from public.moderation_terms t
       where char_length(public.moderation_normalize(t.term)) >= 3
         and case t.match
               when 'substring'
                 then public.moderation_normalize(p_text)
                        ~ public.moderation_pattern(t.term)
               else public.moderation_normalize(p_text)
                        ~ ('(^| )' || public.moderation_pattern(t.term) || '( |$)')
             end
    )
  end;
$function$;

revoke all on function public.moderation_rejects(text) from public;
revoke all on function public.moderation_rejects(text) from anon;
revoke all on function public.moderation_rejects(text) from authenticated;

-- MARK: - Saying which field failed
--
-- The old message named none of the four fields it checked, so somebody whose
-- bio was fine and whose livery was not had nothing to go on. Support cannot
-- answer "why was I rejected" from a message like that either.

create or replace function public.pilot_profiles_guard()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_is_pro boolean;
  v_from_client boolean := auth.uid() is not null;
begin
  new.handle := lower(trim(coalesce(new.handle, '')));
  new.display_name := nullif(btrim(coalesce(new.display_name, '')), '');
  new.bio := nullif(btrim(coalesce(new.bio, '')), '');
  new.if_username := nullif(btrim(coalesce(new.if_username, '')), '');
  new.home_airport := nullif(upper(btrim(coalesce(new.home_airport, ''))), '');
  new.favourite_aircraft := nullif(btrim(coalesce(new.favourite_aircraft, '')), '');
  new.favourite_livery := nullif(btrim(coalesce(new.favourite_livery, '')), '');
  new.accent := nullif(lower(btrim(coalesce(new.accent, ''))), '');

  if tg_op = 'INSERT' then
    if v_from_client then
      new.moderation_state := 'ok';
      new.moderation_note := null;
      new.if_username_verified := false;
    end if;
    new.created_at := now();
    new.handle_changed_at := now();
  else
    if v_from_client then
      new.moderation_state := old.moderation_state;
      new.moderation_note := old.moderation_note;
      new.if_username_verified := old.if_username_verified;
    end if;
    new.created_at := old.created_at;

    if new.handle is distinct from old.handle then
      if old.handle_changed_at > now() - interval '30 days' then
        raise exception
          'A handle can only be changed once every 30 days. Yours last changed on %.',
          to_char(old.handle_changed_at, 'FMDD Month YYYY')
          using errcode = 'check_violation';
      end if;
      new.handle_changed_at := now();
    else
      new.handle_changed_at := old.handle_changed_at;
    end if;
  end if;

  new.updated_at := now();

  if v_from_client
     and ((tg_op = 'INSERT' and (new.banner_path is not null or new.accent is not null))
      or (tg_op = 'UPDATE' and (new.banner_path is distinct from old.banner_path
                                or new.accent is distinct from old.accent))) then
    if coalesce(new.banner_path, '') <> '' or coalesce(new.accent, '') <> '' then
      v_is_pro := public.is_pro_account(new.user_id);
      if not v_is_pro then
        raise exception
          'A custom banner and profile colour are part of Inflight Pro.'
          using errcode = 'insufficient_privilege';
      end if;
    end if;
  end if;

  if not v_from_client then return new; end if;

  if exists (select 1 from public.reserved_handles r where r.handle = new.handle) then
    raise exception 'That handle is reserved.' using errcode = 'check_violation';
  end if;

  -- One check per field, each with its own sentence. Somebody who has to guess
  -- which of four things was wrong will change the wrong one and try again.
  if public.moderation_rejects(new.handle) then
    raise exception 'That handle isn''t one we can allow. Inflight profiles are safe for work.'
      using errcode = 'check_violation';
  end if;

  if public.moderation_rejects(coalesce(new.display_name, '')) then
    raise exception 'That display name isn''t one we can allow. Inflight profiles are safe for work.'
      using errcode = 'check_violation';
  end if;

  if public.moderation_rejects(coalesce(new.bio, '')) then
    raise exception 'Your bio has wording we can''t allow. Inflight profiles are safe for work.'
      using errcode = 'check_violation';
  end if;

  if public.moderation_rejects(coalesce(new.favourite_livery, '')) then
    raise exception 'That livery name isn''t one we can allow. Inflight profiles are safe for work.'
      using errcode = 'check_violation';
  end if;

  return new;
end $function$;

drop trigger if exists pilot_profiles_guard on public.pilot_profiles;
create trigger pilot_profiles_guard
  before insert or update on public.pilot_profiles
  for each row execute function public.pilot_profiles_guard();

-- MARK: - Working out why something was refused
--
-- For support, and for whoever next changes the word list. Service role only:
-- publishing which term matched is publishing the list, and the list is the one
-- thing that has to stay unpublished for the filter to be worth anything.
create or replace function public.moderation_explain(p_text text)
returns table (term text, match text, pattern text)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select t.term, t.match, public.moderation_pattern(t.term)
    from public.moderation_terms t
   where char_length(public.moderation_normalize(t.term)) >= 3
     and case t.match
           when 'substring'
             then public.moderation_normalize(p_text) ~ public.moderation_pattern(t.term)
           else public.moderation_normalize(p_text)
                  ~ ('(^| )' || public.moderation_pattern(t.term) || '( |$)')
         end;
$function$;

revoke all on function public.moderation_explain(text) from public;
revoke all on function public.moderation_explain(text) from anon;
revoke all on function public.moderation_explain(text) from authenticated;
