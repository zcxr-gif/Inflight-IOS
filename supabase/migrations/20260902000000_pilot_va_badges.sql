-- Repping your virtual airline on your own profile.
--
-- WHAT THIS COLUMN IS, AND WHAT IT IS NOT
-- ---------------------------------------
-- It is a PREFERENCE, not a permission. `va_ad_ids` says which VAs a pilot
-- would like to wear and in which order; it says nothing whatever about
-- whether they are entitled to. Postgres cannot answer that question — the VA
-- rosters live in the partner backend's own database, not in this project —
-- so it does not try, and nothing here should ever be read as though it had.
--
-- The entitlement is settled where the rosters are, at the moment the badge is
-- DRAWN: the app resolves these ids against `/api/va-ads/for-pilot`, which
-- answers only with the approved listings the pilot's community handle
-- actually appears on the roster of, and keeps the intersection. That is the
-- same arrangement the web profile card has always used (`ifCardVasFor`), and
-- it is chosen for the same two reasons:
--
--   * A client writing an id it has no claim to achieves nothing. The badge is
--     never drawn — not for them, not for anybody — because the drawing is
--     what performs the check. There is nothing to enforce here that is not
--     already enforced there, and a check in two places is a second chance to
--     get it wrong.
--   * A pilot who LEAVES a VA stops repping it without anybody having to
--     remember to clear the field. Trusting a stored answer would leave the
--     badge up until somebody noticed.
--
-- The honest caveat, and it is the pre-existing one: the roster is matched on
-- `if_username`, and `if_username_verified` is still never set by anything. A
-- profile can claim a community handle it does not own. Every surface that
-- shows the handle already says "claims to be" for exactly this reason, and
-- the badge inherits that caveat rather than adding a new one.

alter table public.pilot_profiles
  add column if not exists va_ad_ids text[] not null default '{}';

comment on column public.pilot_profiles.va_ad_ids is
  'Chosen VA listing ids, in the pilot''s own order. A preference only — '
  'entitlement is resolved against the partner backend''s rosters at draw time.';

-- MARK: - Keeping the column to a shape
--
-- Its own trigger rather than another paragraph inside `pilot_profiles_guard`.
-- That function is a hundred lines of unrelated normalisation and moderation,
-- and reproducing all of it to add four statements is how a migration quietly
-- reverts somebody else's fix. Two `before` triggers on one table fire in name
-- order, and this one sorts after that one, which is the order that reads
-- correctly: the general guard runs, then the column's own rules.
create or replace function public.pilot_profiles_va_guard()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_clean text[];
begin
  -- Trimmed, emptied, de-duplicated and capped, IN THE ORDER GIVEN. The order
  -- is the point of the array — it is which VA the pilot puts first — so this
  -- cannot sort, and `distinct` would not promise to keep it.
  select coalesce(array_agg(x order by ord), '{}')
    into v_clean
    from (
      select x, min(ord) as ord
        from unnest(coalesce(new.va_ad_ids, '{}'::text[])) with ordinality as t(x, ord)
       where btrim(x) <> ''
         -- The ids are the partner backend's object ids, and they are pasted
         -- into a URL path when the badge is resolved. Anything that is not
         -- one is dropped here rather than travelling.
         and btrim(x) ~ '^[A-Za-z0-9_-]{1,64}$'
       group by x
    ) d;

  -- Three. A profile header has room for three marks and a pilot who flies for
  -- nine VAs is not helped by a header that tries to show all of them.
  new.va_ad_ids := v_clean[1:3];

  return new;
end $function$;

drop trigger if exists pilot_profiles_va_guard on public.pilot_profiles;
create trigger pilot_profiles_va_guard
  before insert or update on public.pilot_profiles
  for each row execute function public.pilot_profiles_va_guard();

-- MARK: - Serving it on the card
--
-- Both card functions gain the column. `create or replace` cannot change a
-- function's return type, so both are dropped and rebuilt — the second one is
-- only a signature and a delegation, since its whole body is a call to the
-- first.

drop function if exists public.pilot_profile_by_if_username(text);
drop function if exists public.pilot_profile_card(text);

create or replace function public.pilot_profile_card(p_handle text)
returns table (
  handle text,
  display_name text,
  bio text,
  avatar_path text,
  banner_path text,
  banner_preset text,
  accent text,
  if_username text,
  if_username_verified boolean,
  favourite_aircraft text,
  favourite_livery text,
  home_airport text,
  is_pro boolean,
  friends_visibility text,
  follower_count integer,
  following_count integer,
  friend_count integer,
  joined_at timestamptz,
  viewer_follows boolean,
  follows_viewer boolean,
  is_friend boolean,
  is_self boolean,
  viewer_blocked boolean,
  va_ad_ids text[]
)
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_viewer uuid := auth.uid();
  v_p public.pilot_profiles%rowtype;
  v_pro boolean;
begin
  select * into v_p
    from public.pilot_profiles p
   where p.handle = lower(btrim(coalesce(p_handle, '')));

  -- One answer for "no such handle" and for "you may not see this one".
  -- Distinguishing them would turn this function into a way to enumerate who
  -- has blocked you and which handles are taken by private accounts.
  if not public.pilot_profile_visible(v_p, v_viewer) then
    return;
  end if;

  v_pro := public.is_pro_account(v_p.user_id);

  return query
  select
    v_p.handle,
    coalesce(v_p.display_name, v_p.handle),
    v_p.bio,
    v_p.avatar_path,
    -- The Pro columns are honoured only while Pro is. The values stay in the
    -- row -- a lapsed subscription does not delete the banner somebody made --
    -- but they stop being served, and come back the day the subscription does.
    -- This is the same rule the app applies to a Pro map style, in the one
    -- place a lapsed account cannot argue with it.
    case when v_pro then v_p.banner_path else null end,
    v_p.banner_preset,
    case when v_pro then v_p.accent else null end,
    v_p.if_username,
    v_p.if_username_verified,
    v_p.favourite_aircraft,
    v_p.favourite_livery,
    v_p.home_airport,
    v_pro,
    v_p.friends_visibility,
    (select count(*)::integer from public.pilot_follows f
      where f.following_id = v_p.user_id),
    (select count(*)::integer from public.pilot_follows f
      where f.follower_id = v_p.user_id),
    (select count(*)::integer from public.pilot_follows a
       join public.pilot_follows b
         on b.follower_id = a.following_id and b.following_id = a.follower_id
      where a.follower_id = v_p.user_id),
    v_p.created_at,
    v_viewer is not null and exists (
      select 1 from public.pilot_follows f
       where f.follower_id = v_viewer and f.following_id = v_p.user_id),
    v_viewer is not null and exists (
      select 1 from public.pilot_follows f
       where f.follower_id = v_p.user_id and f.following_id = v_viewer),
    v_viewer is not null and exists (
      select 1 from public.pilot_follows a
       where a.follower_id = v_viewer and a.following_id = v_p.user_id)
      and exists (
      select 1 from public.pilot_follows b
       where b.follower_id = v_p.user_id and b.following_id = v_viewer),
    v_viewer = v_p.user_id,
    v_viewer is not null and exists (
      select 1 from public.pilot_blocks b
       where b.blocker_id = v_viewer and b.blocked_id = v_p.user_id),
    -- Not a Pro column, and deliberately not gated on anything here. Which VAs
    -- a pilot is on the roster of is not ours to ration, and the resolution
    -- that decides whether any of these is drawn happens outside this
    -- database. Served to everybody who can see the card at all.
    coalesce(v_p.va_ad_ids, '{}');
end $function$;

grant execute on function public.pilot_profile_card(text) to anon, authenticated;

-- The same card, found from the name on an aeroplane.
--
-- This is what turns a tapped sprite into a person. Unverified, so the caller
-- gets `if_username_verified` back and is expected to say "claims to be".
-- Oldest claim wins when two profiles name the same pilot: it is the least
-- rewarding rule for somebody who has just noticed a well-known handle is
-- unclaimed here.
create or replace function public.pilot_profile_by_if_username(p_username text)
returns table (
  handle text,
  display_name text,
  bio text,
  avatar_path text,
  banner_path text,
  banner_preset text,
  accent text,
  if_username text,
  if_username_verified boolean,
  favourite_aircraft text,
  favourite_livery text,
  home_airport text,
  is_pro boolean,
  friends_visibility text,
  follower_count integer,
  following_count integer,
  friend_count integer,
  joined_at timestamptz,
  viewer_follows boolean,
  follows_viewer boolean,
  is_friend boolean,
  is_self boolean,
  viewer_blocked boolean,
  va_ad_ids text[]
)
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_handle text;
begin
  select p.handle into v_handle
    from public.pilot_profiles p
   where lower(p.if_username) = lower(btrim(coalesce(p_username, '')))
     and p.is_public
     and p.moderation_state = 'ok'
   order by p.created_at asc
   limit 1;

  if v_handle is null then return; end if;

  return query select * from public.pilot_profile_card(v_handle);
end $function$;

grant execute on function public.pilot_profile_by_if_username(text) to anon, authenticated;
