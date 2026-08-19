-- The accent, in a summary.
--
-- A Pro pilot can choose the colour their profile is drawn in. Until now that
-- colour reached exactly one screen: `pilot_profile_card` serves it, so a
-- profile opened in full is tinted, and nothing else ever saw it. Every list in
-- the app — friends, followers, following, search, the flight window's pilot
-- line — is built from `pilot_summary`, which has no `accent` column, so a
-- pilot's colour was invisible in every place their name actually appears next
-- to somebody else's.
--
-- Adding the attribute is not optional-feeling: a `setof pilot_summary`
-- function whose select list is one column short of the type fails at run time,
-- so every one of the four is recreated here in the same transaction. They are
-- otherwise unchanged — the only edit is the column on the end.
--
-- Pro-gated exactly the way the card gates it (`20260818000200`, line ~298):
-- the stored value stays in the row when a subscription lapses, and the server
-- simply stops serving it. Nothing is taken away, and nothing has to be
-- remembered by the client.

begin;

-- Idempotent: a migration that has already run leaves the attribute alone
-- rather than erroring, which is what makes it safe to re-apply against a
-- project somebody has already pointed this at.
do $$
begin
  if not exists (
    select 1
      from pg_type t
      join pg_class c on c.oid = t.typrelid
      join pg_attribute a on a.attrelid = c.oid
     where t.typname = 'pilot_summary'
       and t.typnamespace = 'public'::regnamespace
       and a.attname = 'accent'
       and not a.attisdropped
  ) then
    alter type public.pilot_summary add attribute accent text cascade;
  end if;
end $$;

create or replace function public.pilot_profile_friends(
  p_handle text,
  p_limit integer default 60
)
returns setof public.pilot_summary
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_viewer uuid := auth.uid();
  v_p public.pilot_profiles%rowtype;
begin
  select * into v_p from public.pilot_profiles p
   where p.handle = lower(btrim(coalesce(p_handle, '')));

  if not public.pilot_profile_visible(v_p, v_viewer) then return; end if;

  -- The friends list is other people's names, so it has a control the rest of
  -- the profile does not.
  if v_p.friends_visibility = 'private' and v_viewer is distinct from v_p.user_id then
    return;
  end if;

  if v_p.friends_visibility = 'followers' and v_viewer is distinct from v_p.user_id then
    if v_viewer is null or not exists (
      select 1 from public.pilot_follows f
       where f.follower_id = v_viewer and f.following_id = v_p.user_id
    ) then
      return;
    end if;
  end if;

  return query
  select fp.handle,
         coalesce(fp.display_name, fp.handle),
         fp.avatar_path,
         fp.if_username,
         fp.favourite_aircraft,
         fp.home_airport,
         public.is_pro_account(fp.user_id),
         case when public.is_pro_account(fp.user_id)
              then fp.accent else null end
    from public.pilot_follows a
    join public.pilot_follows b
      on b.follower_id = a.following_id and b.following_id = a.follower_id
    join public.pilot_profiles fp on fp.user_id = a.following_id
   where a.follower_id = v_p.user_id
     -- A friend whose own profile has gone private or been hidden drops off
     -- everybody else's list at the same moment it stops being readable.
     and fp.is_public
     and fp.moderation_state = 'ok'
     and not exists (
       select 1 from public.pilot_blocks bl
        where bl.blocker_id = fp.user_id and bl.blocked_id = v_viewer)
   order by greatest(a.created_at, b.created_at) desc
   limit least(greatest(coalesce(p_limit, 60), 1), 200);
end $function$;

grant execute on function public.pilot_profile_friends(text, integer) to anon, authenticated;

create or replace function public.pilot_profile_connections(
  p_handle text,
  p_direction text default 'followers',
  p_limit integer default 60,
  p_offset integer default 0
)
returns setof public.pilot_summary
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_viewer uuid := auth.uid();
  v_p public.pilot_profiles%rowtype;
  v_dir text := lower(coalesce(p_direction, 'followers'));
begin
  if v_dir not in ('followers', 'following') then
    raise exception 'Direction must be followers or following.'
      using errcode = 'invalid_parameter_value';
  end if;

  select * into v_p from public.pilot_profiles p
   where p.handle = lower(btrim(coalesce(p_handle, '')));

  if not public.pilot_profile_visible(v_p, v_viewer) then return; end if;

  return query
  select fp.handle,
         coalesce(fp.display_name, fp.handle),
         fp.avatar_path,
         fp.if_username,
         fp.favourite_aircraft,
         fp.home_airport,
         public.is_pro_account(fp.user_id),
         case when public.is_pro_account(fp.user_id)
              then fp.accent else null end
    from (
      select case when v_dir = 'followers' then f.follower_id else f.following_id end as uid,
             f.created_at
        from public.pilot_follows f
       where (v_dir = 'followers' and f.following_id = v_p.user_id)
          or (v_dir = 'following' and f.follower_id = v_p.user_id)
    ) other
    join public.pilot_profiles fp on fp.user_id = other.uid
   where fp.is_public
     and fp.moderation_state = 'ok'
     and not exists (
       select 1 from public.pilot_blocks bl
        where bl.blocker_id = fp.user_id and bl.blocked_id = v_viewer)
   order by other.created_at desc
   limit least(greatest(coalesce(p_limit, 60), 1), 200)
  offset greatest(coalesce(p_offset, 0), 0);
end $function$;

grant execute on function public.pilot_profile_connections(text, text, integer, integer)

create or replace function public.pilot_directory_search(
  p_query text,
  p_limit integer default 25
)
returns setof public.pilot_summary
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_viewer uuid := auth.uid();
  v_q text := lower(btrim(coalesce(p_query, '')));
begin
  -- Two characters is the floor. One character would return the directory.
  if char_length(v_q) < 2 then return; end if;

  return query
  select p.handle,
         coalesce(p.display_name, p.handle),
         p.avatar_path,
         p.if_username,
         p.favourite_aircraft,
         p.home_airport,
         public.is_pro_account(p.user_id),
         case when public.is_pro_account(p.user_id)
              then p.accent else null end
    from public.pilot_profiles p
   where p.is_public
     and p.moderation_state = 'ok'
     and (p.handle like v_q || '%'
          or lower(coalesce(p.display_name, '')) like '%' || v_q || '%'
          or lower(coalesce(p.if_username, '')) like v_q || '%')
     and not exists (
       select 1 from public.pilot_blocks bl
        where bl.blocker_id = p.user_id and bl.blocked_id = v_viewer)
   -- An exact handle is what somebody typing a whole handle is looking for,
   -- and it should not be third behind two people whose bio mentions them.
   order by (p.handle = v_q) desc,
            (p.handle like v_q || '%') desc,
            p.handle asc
   limit least(greatest(coalesce(p_limit, 25), 1), 50);
end $function$;

grant execute on function public.pilot_directory_search(text, integer) to anon, authenticated;

create or replace function public.pilot_blocked_list()
returns setof public.pilot_summary
language sql
stable
security definer
set search_path to 'public'
as $function$
  select p.handle,
         coalesce(p.display_name, p.handle),
         p.avatar_path,
         p.if_username,
         p.favourite_aircraft,
         p.home_airport,
         public.is_pro_account(p.user_id),
         case when public.is_pro_account(p.user_id)
              then p.accent else null end
    from public.pilot_blocks b
    join public.pilot_profiles p on p.user_id = b.blocked_id
   where b.blocker_id = auth.uid()
   order by b.created_at desc;
$function$;

grant execute on function public.pilot_blocked_list() to authenticated;

commit;
