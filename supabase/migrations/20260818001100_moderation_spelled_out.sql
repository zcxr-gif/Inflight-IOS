-- Also read text that is being spelled out letter by letter.
--
-- "n u d e s" walked straight through, before the previous migration and after
-- it: spaces survive normalisation, so the letters never form the word. It was
-- never a regression — it was a hole that had been there since the filter
-- shipped, found while building the corpus to prove the false-positive fix.
--
-- The obvious fix — test the text with all spaces removed — is worse than the
-- hole. "shop ornaments" de-spaced is "shopornaments", which contains "porn",
-- and refusing somebody's bio for mentioning ornaments is exactly the class of
-- bug this pair of migrations exists to undo.
--
-- So the de-spaced form is only ever considered when the text is ACTUALLY being
-- spelled out: three or more consecutive single-letter words. That is what
-- "n u d e s" looks like and what no ordinary sentence looks like. Both forms
-- are then tested, and either one matching is a refusal.

create or replace function public.moderation_rejects(p_text text)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $function$
  with subject as (
    select public.moderation_normalize(p_text) as plain
  ),
  forms as (
    select plain as form from subject where plain <> ''
    union
    select replace(plain, ' ', '') from subject
     where plain ~ '(^| )[a-z] [a-z] [a-z]( |$)'
  )
  select exists (
    select 1
      from forms f
      cross join public.moderation_terms t
     where char_length(public.moderation_normalize(t.term)) >= 3
       and case t.match
             when 'substring'
               then f.form ~ public.moderation_pattern(t.term)
             else f.form ~ ('(^| )' || public.moderation_pattern(t.term) || '( |$)')
           end
  );
$function$;

revoke all on function public.moderation_rejects(text) from public;
revoke all on function public.moderation_rejects(text) from anon;
revoke all on function public.moderation_rejects(text) from authenticated;
